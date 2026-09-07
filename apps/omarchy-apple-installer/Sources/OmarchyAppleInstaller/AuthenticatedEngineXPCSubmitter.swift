#if os(macOS)
  import Darwin
  import Foundation
  import Security

  @objc public protocol ClosedEngineXPCService {
    /// Answers as soon as the helper is up. The app calls this before it
    /// sends anything, so a helper that launchd cannot keep alive fails in
    /// seconds instead of leaving a request queued forever.
    func ping(reply: @escaping @Sendable (Bool) -> Void)

    func removal(
      ticket: String, confirmation: String, machineOwner: String, password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    func submit(
      packageDirectory: FileHandle,
      operation: String,
      machineOwner: String,
      password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    )
  }

  public enum EngineXPCSubmissionError: Error, Equatable, Sendable {
    case invalidMachServiceName
    case invalidCodeSigningRequirement
    case unsafeHandoffPackage
    case connectionFailed
    /// The helper did not answer a ping within the allowed time. Seen when
    /// launchd respawns a helper that exits at startup: the mach message
    /// stays queued and nothing ever replies or interrupts.
    case helperUnresponsive
    case recoveryAuthorizationFailed
    case machineOwnerCredentialsRejected
    case helperRejected(domain: String, code: Int)
    case emptyResponse
  }

  public struct AuthenticatedEngineXPCSubmitter:
    EngineHandoffSubmitting, Sendable
  {
    private let machServiceName: String
    private let helperCodeSigningRequirement: String
    private let journalProgress: (@Sendable (Data) -> Void)?

    public init(
      machServiceName: String,
      helperCodeSigningRequirement: String,
      journalProgress: (@Sendable (Data) -> Void)? = nil
    ) throws {
      guard Self.isMachServiceName(machServiceName) else {
        throw EngineXPCSubmissionError.invalidMachServiceName
      }
      guard
        EngineCodeSigningRequirement.isValid(
          helperCodeSigningRequirement
        )
      else {
        throw EngineXPCSubmissionError.invalidCodeSigningRequirement
      }
      self.machServiceName = machServiceName
      self.helperCodeSigningRequirement = helperCodeSigningRequirement
      self.journalProgress = journalProgress
    }

    /// A privileged connection to the helper, pinned to its code-signing
    /// requirement; each call gets its own so a dead one never lingers.
    private func makeConnection() -> NSXPCConnection {
      let connection = NSXPCConnection(
        machServiceName: machServiceName,
        options: .privileged
      )
      connection.remoteObjectInterface = NSXPCInterface(
        with: ClosedEngineXPCService.self
      )
      connection.setCodeSigningRequirement(helperCodeSigningRequirement)
      return connection
    }

    /// Confirms the helper answers before any credentials or package are
    /// sent. A missing service fails through the connection handlers; a
    /// service launchd cannot keep alive answers nothing at all, which is
    /// what the timeout is for.
    public func ping(timeout: Duration = .seconds(8)) async throws {
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      let timer = Task {
        try await Task.sleep(for: timeout)
        connectionHandle.invalidate()
      }
      defer { timer.cancel() }
      let answered: Bool = try await withCheckedThrowingContinuation { continuation in
        let gate = EngineXPCPingGate(continuation: continuation)
        connection.interruptionHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.invalidationHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.helperUnresponsive)
        }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
          }) as? ClosedEngineXPCService
        else {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
          connectionHandle.invalidate()
          return
        }
        proxy.ping { answer in
          gate.resume(returning: answer)
          connectionHandle.invalidate()
        }
      }
      guard answered else {
        throw EngineXPCSubmissionError.helperUnresponsive
      }
    }

    public func removal(
      ticket: OmarchyRemovalTicket? = nil, confirmation: String = "",
      authorization: MachineOwnerAuthorization? = nil
    ) async throws -> OmarchyRemovalReply {
      try await ping()
      let connection = makeConnection()
      let handle = SendableXPCConnection(connection)
      let data: Data = try await withCheckedThrowingContinuation { continuation in
        let gate = EngineXPCReplyGate(continuation: continuation)
        connection.interruptionHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.invalidationHandler = {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
        }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
            handle.invalidate()
          }) as? ClosedEngineXPCService
        else {
          gate.resume(throwing: EngineXPCSubmissionError.connectionFailed)
          handle.invalidate()
          return
        }
        proxy.removal(
          ticket: ticket?.id.uuidString ?? "", confirmation: confirmation,
          machineOwner: authorization?.username ?? "", password: authorization?.password ?? Data()
        ) { response, error in
          defer { handle.invalidate() }
          if let error {
            gate.resume(throwing: error)
          } else if let response {
            gate.resume(returning: response)
          } else {
            gate.resume(throwing: EngineXPCSubmissionError.emptyResponse)
          }
        }
      }
      return try JSONDecoder().decode(OmarchyRemovalReply.self, from: data)
    }

    public func submit(
      _ handoff: PreparedEngineHandoff,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation
    ) async throws -> Data {
      let descriptor = Darwin.open(
        handoff.packageURL.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else {
        throw EngineXPCSubmissionError.unsafeHandoffPackage
      }

      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFDIR,
        status.st_mode & 0o077 == 0
      else {
        Darwin.close(descriptor)
        throw EngineXPCSubmissionError.unsafeHandoffPackage
      }

      let directoryHandle = FileHandle(
        fileDescriptor: descriptor,
        closeOnDealloc: true
      )
      let connection = makeConnection()
      let connectionHandle = SendableXPCConnection(connection)
      if let journalProgress {
        connection.exportedInterface = NSXPCInterface(
          with: ClosedEngineProgressClient.self
        )
        connection.exportedObject = EngineProgressClientRelay(
          handler: journalProgress
        )
      }

      return try await withCheckedThrowingContinuation { continuation in
        let gate = EngineXPCReplyGate(continuation: continuation)
        connection.interruptionHandler = {
          gate.resume(
            throwing: EngineXPCSubmissionError.connectionFailed
          )
        }
        connection.invalidationHandler = {
          gate.resume(
            throwing: EngineXPCSubmissionError.connectionFailed
          )
        }
        connection.activate()

        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.resume(
              throwing: EngineXPCSubmissionError.connectionFailed
            )
            connectionHandle.invalidate()
          }) as? ClosedEngineXPCService
        else {
          gate.resume(
            throwing: EngineXPCSubmissionError.connectionFailed
          )
          connectionHandle.invalidate()
          return
        }

        proxy.submit(
          packageDirectory: directoryHandle,
          operation: operation.rawValue,
          machineOwner: authorization.username,
          password: authorization.password
        ) { response, error in
          defer { connectionHandle.invalidate() }
          if let error {
            gate.resume(
              throwing: EngineXPCErrorBridge.submissionError(error)
            )
          } else if let response, !response.isEmpty {
            gate.resume(returning: response)
          } else {
            gate.resume(
              throwing: EngineXPCSubmissionError.emptyResponse
            )
          }
        }
      }
    }

    static func isMachServiceName(_ value: String) -> Bool {
      guard (3...255).contains(value.utf8.count),
        value.contains("."),
        value.first != ".",
        value.last != "."
      else {
        return false
      }
      return value.utf8.allSatisfy { byte in
        (byte >= 48 && byte <= 57)
          || (byte >= 65 && byte <= 90)
          || (byte >= 97 && byte <= 122)
          || byte == 45
          || byte == 46
      }
    }
  }

  enum EngineXPCErrorBridge {
    private static let recoveryAuthorizationDomain =
      "com.omarchy.mx.installer.recovery-authorization"
    private static let recoveryAuthorizationCode = 1
    // Dedicated domain so the app can tell "wrong password" from every other
    // helper rejection. Skew-safe: an older app maps this unknown domain to the
    // generic helperRejected case exactly as it does today.
    static let machineOwnerAuthorizationDomain =
      "com.omarchy.mx.installer.machine-owner-authorization"
    static let machineOwnerAuthorizationCode = 1

    static func serviceError(for error: any Error) -> NSError {
      if let executionError = error
        as? PinnedAsahiEngineExecutionError,
        executionError == .recoveryAuthorizationFailed
      {
        return NSError(
          domain: recoveryAuthorizationDomain,
          code: recoveryAuthorizationCode,
          userInfo: [:]
        )
      }
      if let helperError = error as? ClosedEngineHelperError,
        helperError == .invalidMachineOwnerCredentials
      {
        return NSError(
          domain: machineOwnerAuthorizationDomain,
          code: machineOwnerAuthorizationCode,
          userInfo: [:]
        )
      }
      return error as NSError
    }

    static func submissionError(
      _ error: NSError
    ) -> EngineXPCSubmissionError {
      if error.domain == recoveryAuthorizationDomain,
        error.code == recoveryAuthorizationCode
      {
        return .recoveryAuthorizationFailed
      }
      if error.domain == machineOwnerAuthorizationDomain,
        error.code == machineOwnerAuthorizationCode
      {
        return .machineOwnerCredentialsRejected
      }
      return .helperRejected(
        domain: error.domain,
        code: error.code
      )
    }
  }

  public enum RecoveryAuthorizationRetryPolicy {
    public static func isEligible(after error: any Error) -> Bool {
      guard let submissionError = error as? EngineXPCSubmissionError
      else {
        return false
      }
      return submissionError == .recoveryAuthorizationFailed
    }
  }

  enum EngineCodeSigningRequirement {
    static func isValid(_ value: String) -> Bool {
      guard !value.isEmpty, value.utf8.count <= 4_096 else {
        return false
      }
      var requirement: SecRequirement?
      let status = SecRequirementCreateWithString(
        value as CFString,
        SecCSFlags(),
        &requirement
      )
      return status == errSecSuccess && requirement != nil
    }
  }

  private final class SendableXPCConnection: @unchecked Sendable {
    private let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
      self.connection = connection
    }

    func invalidate() {
      connection.invalidate()
    }
  }

  /// One-shot resume for `ping`, the same shape as the reply gate below.
  private final class EngineXPCPingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, any Error>?

    init(continuation: CheckedContinuation<Bool, any Error>) {
      self.continuation = continuation
    }

    func resume(returning value: Bool) {
      takeContinuation()?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
      takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<Bool, any Error>? {
      lock.lock()
      defer { lock.unlock() }
      let candidate = continuation
      continuation = nil
      return candidate
    }
  }

  private final class EngineXPCReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?

    init(continuation: CheckedContinuation<Data, any Error>) {
      self.continuation = continuation
    }

    func resume(returning data: Data) {
      takeContinuation()?.resume(returning: data)
    }

    func resume(throwing error: any Error) {
      takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<Data, any Error>? {
      lock.lock()
      defer { lock.unlock() }
      let candidate = continuation
      continuation = nil
      return candidate
    }
  }
#endif
