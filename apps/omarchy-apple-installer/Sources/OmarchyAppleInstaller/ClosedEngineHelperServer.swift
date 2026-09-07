#if os(macOS)
  import Foundation
  import Darwin

  public enum EngineHandoffOperation: String, Equatable, Sendable {
    case install
    case retryRecoveryAuthorization = "retry-recovery-authorization"
  }

  public protocol ImportedEngineHandoffExecuting: Sendable {
    func execute(
      _ package: ImportedEngineHandoffPackage,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation
    ) async throws -> Data
  }

  public enum ClosedEngineHelperError: Error, Equatable, Sendable {
    case busy
    case invalidOperation
    case invalidMachineOwnerCredentials
    case invalidClientRequirement
    case unsupportedDevice(String)
    case transcriptDeviceMismatch
    case transcriptIncomplete
    case transcriptPlanMismatch
  }

  public actor ClosedEngineHelperServer {
    private static let explicitlyUnsupportedDevices = ["apple,j614s"]

    private let workingDirectory: URL
    private let credentialValidator: any MachineOwnerCredentialValidating
    private let executor: any ImportedEngineHandoffExecuting
    private let importer: EngineHandoffPackageImporter
    private let removalDisks: any RemovalDiskOperating
    private let removalAdminValidator: @Sendable (MachineOwnerAuthorization) throws -> Void
    private var isExecuting = false
    private var removalPlan:
      (ticket: OmarchyRemovalTicket, plan: OmarchyRemovalPlan, expires: Date)?

    public init(
      workingDirectory: URL,
      executor: any ImportedEngineHandoffExecuting,
      credentialValidator: any MachineOwnerCredentialValidating =
        OpenDirectoryMachineOwnerCredentialValidator()
    ) {
      self.workingDirectory = workingDirectory
      self.executor = executor
      self.credentialValidator = credentialValidator
      importer = EngineHandoffPackageImporter()
      removalDisks = MacRemovalDiskOperator()
      removalAdminValidator = requireRemovalAdministrator
    }

    init(
      workingDirectory: URL, executor: any ImportedEngineHandoffExecuting,
      credentialValidator: any MachineOwnerCredentialValidating,
      removalDisks: any RemovalDiskOperating,
      removalAdminValidator: @escaping @Sendable (MachineOwnerAuthorization) throws -> Void
    ) {
      self.workingDirectory = workingDirectory
      self.executor = executor
      self.credentialValidator = credentialValidator
      importer = EngineHandoffPackageImporter()
      self.removalDisks = removalDisks
      self.removalAdminValidator = removalAdminValidator
    }

    public func removal(
      ticketID: UUID?, confirmation: String, authorization: MachineOwnerAuthorization?
    ) async throws -> OmarchyRemovalReply {
      guard !isExecuting else { throw ClosedEngineHelperError.busy }
      try requireNoInterruptedRemoval()
      isExecuting = true
      defer { isExecuting = false }
      let disks = removalDisks
      let validateAdministrator = removalAdminValidator
      if ticketID == nil {
        removalPlan = nil
        let plan = try await Task.detached {
          try OmarchyRemovalPlan(snapshot: disks.snapshot())
        }.value
        let ticket = OmarchyRemovalTicket(
          id: UUID(), reclaimBytes: plan.reclaimBytes, macOSBytesAfter: plan.targetMacOSBytes)
        removalPlan = (ticket, plan, Date().addingTimeInterval(300))
        return OmarchyRemovalReply(
          ticket: ticket, message: "The installation and all its data will be permanently deleted.")
      }
      guard confirmation == OmarchyRemovalTicket.confirmation,
        let authorization, let approved = removalPlan,
        approved.ticket.id == ticketID, approved.expires > Date()
      else {
        throw RemovalFailure(
          message:
            "The confirmation is incorrect or has expired. Close this window and review removal again. Nothing was changed."
        )
      }
      // One use only, including failures. A fresh review must obtain a new plan.
      removalPlan = nil
      let validator = credentialValidator
      let workingDirectory = self.workingDirectory
      let journalURL = workingDirectory.appendingPathComponent(
        "removal-\(approved.ticket.id.uuidString).json")
      return await Task.detached {
        var phase = "checking"
        do {
          do { try validator.validate(authorization) } catch {
            throw RemovalFailure(message: "The macOS account or password was not accepted.")
          }
          try validateAdministrator(authorization)
          let executor = OmarchyRemovalExecutor(disks: disks)
          try executor.execute(approved.plan) { next in
            // The private journal is durable before each mutation, without credentials.
            let journal = RemovalJournal(plan: approved.plan, phase: next)
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            let file = try FileHandle(forWritingTo: journalURL)
            try file.synchronize()
            try file.close()
            let directory = open(workingDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard directory >= 0 else {
              throw RemovalFailure(message: "The removal journal could not be saved.")
            }
            defer { Darwin.close(directory) }
            guard fsync(directory) == 0 else {
              throw RemovalFailure(message: "The removal journal could not be saved.")
            }
            phase = next
          }
          return OmarchyRemovalReply(
            completed: true,
            message: "Omarchy and its data have been removed. The freed space is now part of macOS."
          )
        } catch {
          let detail = (error as? RemovalFailure)?.message ?? "macOS could not complete removal."
          let message: String
          if phase == "checking" {
            message = "\(detail) No disk changes were made."
          } else if phase == "returning-space-to-macos" || phase == "complete" {
            message =
              "Omarchy was removed, but returning its space to macOS could not be confirmed. The space may still be unallocated. \(detail) Do not repeat deletion; the removal journal was kept for recovery."
          } else {
            message =
              "Removal stopped and some Omarchy data may already be deleted. \(detail) Do not repeat deletion; the removal journal was kept for recovery."
          }
          return OmarchyRemovalReply(requiresReview: phase != "checking", message: message)
        }
      }.value
    }

    private func requireNoInterruptedRemoval() throws {
      let entries = try FileManager.default.contentsOfDirectory(
        at: workingDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      for entry in entries
      where entry.lastPathComponent.hasPrefix("removal-") && entry.pathExtension == "json" {
        let properties = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
          let journal = try? JSONDecoder().decode(
            RemovalJournal.self, from: Data(contentsOf: entry)),
          journal.phase == "complete"
        else {
          throw RemovalFailure(
            message:
              "An earlier removal did not finish. Review the saved removal journal and disk layout before making further disk changes."
          )
        }
      }
    }

    /// `progress` is optional and advisory: when a connected app exports the
    /// journal callback, the helper tails the run's journal and forwards whole
    /// lines. Passing nil reproduces the previous behavior exactly.
    public func submit(
      packageDirectory: FileHandle,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation = .install,
      progress: (any EngineJournalProgressSink)? = nil
    ) async throws -> Data {
      guard !isExecuting else {
        throw ClosedEngineHelperError.busy
      }
      try requireNoInterruptedRemoval()
      isExecuting = true
      defer { isExecuting = false }

      do {
        try InstallerPerformance.measure("credential_validation") {
          try credentialValidator.validate(authorization)
        }
      } catch {
        throw ClosedEngineHelperError.invalidMachineOwnerCredentials
      }

      let package = try InstallerPerformance.measure("helper_import") {
        try importer.prepare(from: packageDirectory, in: workingDirectory)
      }
      defer { try? FileManager.default.removeItem(at: package.packageURL) }

      guard
        !Self.explicitlyUnsupportedDevices.contains(
          package.deviceIdentifier
        )
      else {
        throw ClosedEngineHelperError.unsupportedDevice(
          package.deviceIdentifier
        )
      }

      var tailer: EngineJournalTailer?
      if let progress,
        let journalURL = EngineJournalLocator.journalURL(
          workingDirectory: workingDirectory,
          bindingDigest: package.bindingDigest
        )
      {
        let started = EngineJournalTailer(
          journalURL: journalURL,
          expectedOwner: geteuid(),
          sink: progress
        )
        await started.start()
        tailer = started
      }

      let result: Data
      do {
        result = try await executor.execute(
          package,
          authorization: authorization,
          operation: operation
        )
      } catch {
        await tailer?.stop()
        throw error
      }
      await tailer?.stop()

      let transcript = try AppleInstallerTrustCore()
        .validateEngineTranscript(result)
      guard transcript.support == .supported else {
        throw ClosedEngineHelperError.unsupportedDevice(
          package.deviceIdentifier
        )
      }
      guard transcript.deviceIdentifier == package.deviceIdentifier,
        transcript.plan?.deviceIdentifier == package.deviceIdentifier
      else {
        throw ClosedEngineHelperError.transcriptDeviceMismatch
      }
      guard transcript.plan?.planDigest == package.planDigest else {
        throw ClosedEngineHelperError.transcriptPlanMismatch
      }
      guard transcript.completion != nil else {
        throw ClosedEngineHelperError.transcriptIncomplete
      }
      return result
    }
  }

  private struct RemovalJournal: Codable {
    let plan: OmarchyRemovalPlan
    let phase: String
  }

  public final class ClosedEngineXPCServiceEndpoint:
    NSObject, ClosedEngineXPCService
  {
    private let server: ClosedEngineHelperServer

    public init(server: ClosedEngineHelperServer) {
      self.server = server
    }

    public func ping(reply: @escaping @Sendable (Bool) -> Void) {
      reply(true)
    }

    public func removal(
      ticket: String, confirmation: String, machineOwner: String, password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
      let server = server
      Task {
        do {
          guard ticket.isEmpty || UUID(uuidString: ticket) != nil,
            confirmation.utf8.count <= 256
          else { throw ClosedEngineHelperError.invalidOperation }
          let authorization =
            ticket.isEmpty
            ? nil : try MachineOwnerAuthorization(username: machineOwner, password: password)
          let result = try await server.removal(
            ticketID: UUID(uuidString: ticket), confirmation: confirmation,
            authorization: authorization)
          reply(try JSONEncoder().encode(result), nil)
        } catch {
          let message =
            (error as? RemovalFailure)?.message
            ?? "The helper could not prepare removal. Make sure this version of the app and its helper are installed and no installation is running."
          reply(try? JSONEncoder().encode(OmarchyRemovalReply(message: message)), nil)
        }
      }
    }

    public func submit(
      packageDirectory: FileHandle,
      operation: String,
      machineOwner: String,
      password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
      // NSXPCConnection.current() is only valid synchronously inside the
      // exported method, so the client proxy is captured before the Task.
      let client =
        NSXPCConnection.current()?
        .remoteObjectProxyWithErrorHandler { _ in
          // The peer exports no progress client: streaming stays off and the
          // authoritative reply path is untouched.
        } as? ClosedEngineProgressClient
      let sink = client.map(XPCJournalProgressSink.init(client:))
      let server = server
      Task {
        do {
          guard let operation = EngineHandoffOperation(rawValue: operation)
          else {
            throw ClosedEngineHelperError.invalidOperation
          }
          let authorization = try MachineOwnerAuthorization(
            username: machineOwner,
            password: password
          )
          let response = try await server.submit(
            packageDirectory: packageDirectory,
            authorization: authorization,
            operation: operation,
            progress: sink
          )
          reply(response, nil)
        } catch {
          reply(nil, EngineXPCErrorBridge.serviceError(for: error))
        }
      }
    }
  }

  public final class AuthenticatedEngineXPCListenerDelegate:
    NSObject, NSXPCListenerDelegate
  {
    private let clientCodeSigningRequirement: String
    private let endpoint: ClosedEngineXPCServiceEndpoint

    public init(
      clientCodeSigningRequirement: String,
      server: ClosedEngineHelperServer
    ) throws {
      guard
        EngineCodeSigningRequirement.isValid(
          clientCodeSigningRequirement
        )
      else {
        throw ClosedEngineHelperError.invalidClientRequirement
      }
      self.clientCodeSigningRequirement = clientCodeSigningRequirement
      endpoint = ClosedEngineXPCServiceEndpoint(server: server)
    }

    public func listener(
      _ listener: NSXPCListener,
      shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
      connection.setCodeSigningRequirement(clientCodeSigningRequirement)
      connection.remoteObjectInterface = NSXPCInterface(
        with: ClosedEngineProgressClient.self
      )
      connection.exportedInterface = NSXPCInterface(
        with: ClosedEngineXPCService.self
      )
      connection.exportedObject = endpoint
      connection.activate()
      return true
    }
  }
#endif
