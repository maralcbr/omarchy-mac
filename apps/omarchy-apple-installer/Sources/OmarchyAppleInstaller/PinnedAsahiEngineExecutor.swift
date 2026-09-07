#if os(macOS)
  import CryptoKit
  import Darwin
  import Foundation

  public enum PinnedAsahiEngineExecutionError:
    Error, Equatable, Sendable
  {
    case privilegeRequired
    case invalidArchiveIdentity
    case unsafeArchive
    case archiveSizeMismatch
    case archiveDigestMismatch
    case unsafeArchiveEntry
    case extractionFailed(Int32)
    case invalidBundle
    case launchFailed
    case engineExited(Int32)
    case recoveryAuthorizationFailed
    case unsafeTranscript
  }

  public struct PinnedAsahiEngineArchive: Equatable, Sendable {
    public let fileURL: URL
    public let expectedDigest: String
    public let expectedSizeBytes: UInt64

    public init(
      fileURL: URL,
      expectedDigest: String,
      expectedSizeBytes: UInt64
    ) throws {
      guard fileURL.isFileURL,
        SHA256Digest(rawValue: expectedDigest) != nil,
        expectedSizeBytes > 0,
        expectedSizeBytes <= UInt64(PinnedAsahiEngineExecutor.maximumArchiveBytes)
      else {
        throw PinnedAsahiEngineExecutionError.invalidArchiveIdentity
      }
      self.fileURL = fileURL
      self.expectedDigest = expectedDigest
      self.expectedSizeBytes = expectedSizeBytes
    }
  }

  public struct PinnedAsahiEngineExecutor:
    ImportedEngineHandoffExecuting, Sendable
  {
    public static let maximumArchiveBytes: Int64 = 67_108_864
    public static let maximumTranscriptBytes: Int64 = 8_388_608

    private let effectiveUserID: @Sendable () -> uid_t
    private let expectedFileOwnerID: @Sendable () -> uid_t
    private let extractionOptions: [String]

    public init() {
      effectiveUserID = { geteuid() }
      expectedFileOwnerID = { geteuid() }
      extractionOptions = []
    }

    init(
      effectiveUserID: @escaping @Sendable () -> uid_t,
      expectedFileOwnerID: @escaping @Sendable () -> uid_t = { geteuid() },
      extractionOptions: [String] = []
    ) {
      self.effectiveUserID = effectiveUserID
      self.expectedFileOwnerID = expectedFileOwnerID
      self.extractionOptions = extractionOptions
    }

    public func execute(
      _ package: ImportedEngineHandoffPackage,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation = .install
    ) async throws -> Data {
      guard effectiveUserID() == 0 else {
        throw PinnedAsahiEngineExecutionError.privilegeRequired
      }
      let journal = try preparePersistentJournal(for: package)
      return try run(
        archive: package.engineURL,
        executionParent: package.packageURL.deletingLastPathComponent(),
        journal: journal,
        additionalEnvironment: installEnvironment(
          package: package,
          authorization: authorization,
          operation: operation
        ),
        standardInput: authorization.password + Data([10]),
        retryIdentity: RecoveryRetryIdentity(package: package)
      )
    }

    public func inspect(
      _ archive: PinnedAsahiEngineArchive,
      repairManifestURL: URL? = nil,
      in scratchDirectory: URL
    ) async throws -> Data {
      try validateJournalDirectory(scratchDirectory)
      return try run(
        archive: archive.fileURL,
        expectedDigest: archive.expectedDigest,
        expectedSizeBytes: archive.expectedSizeBytes,
        executionParent: scratchDirectory,
        journal: nil,
        additionalEnvironment: repairEnvironment(
          mode: "inspect",
          repairManifestURL: repairManifestURL
        )
      )
    }

    public func plan(
      _ archive: PinnedAsahiEngineArchive,
      request: PinnedAsahiPlanRequest,
      identity: PinnedAsahiPlanIdentity,
      repairManifestURL: URL? = nil,
      in scratchDirectory: URL
    ) async throws -> Data {
      try validateJournalDirectory(scratchDirectory)
      let inputDirectory = scratchDirectory.appendingPathComponent(
        "engine-plan-input-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: inputDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      defer { try? FileManager.default.removeItem(at: inputDirectory) }

      let requestURL = inputDirectory.appendingPathComponent("request.json")
      let identityURL = inputDirectory.appendingPathComponent("identity.json")
      try writePrivateJSON(request, to: requestURL)
      try writePrivateJSON(identity, to: identityURL)
      return try run(
        archive: archive.fileURL,
        expectedDigest: archive.expectedDigest,
        expectedSizeBytes: archive.expectedSizeBytes,
        executionParent: scratchDirectory,
        journal: nil,
        additionalEnvironment: repairEnvironment(
          mode: "plan",
          repairManifestURL: repairManifestURL,
          additional: [
            "OMARCHY_ENGINE_MODE": "plan",
            "OMARCHY_ENGINE_REQUEST": requestURL.path,
            "OMARCHY_ENGINE_IDENTITY": identityURL.path,
          ]
        )
      )
    }

    private func run(
      archive: URL,
      expectedDigest: String? = nil,
      expectedSizeBytes: UInt64? = nil,
      executionParent: URL,
      journal: URL?,
      additionalEnvironment: [String: String],
      standardInput: Data? = nil,
      retryIdentity: RecoveryRetryIdentity? = nil
    ) throws -> Data {
      try validateArchive(
        archive,
        expectedDigest: expectedDigest,
        expectedSizeBytes: expectedSizeBytes
      )

      let executionRoot =
        executionParent
        .appendingPathComponent(
          "engine-execution-\(UUID().uuidString.lowercased())",
          isDirectory: true
        )
      try FileManager.default.createDirectory(
        at: executionRoot,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      defer { try? FileManager.default.removeItem(at: executionRoot) }

      let bundle = executionRoot.appendingPathComponent(
        "bundle",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: bundle,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      try validateArchiveEntries(archive)
      try extract(archive, into: bundle)
      try validateExtractedBundle(bundle)

      let transcriptURL =
        journal
        ?? executionRoot.appendingPathComponent(
          "transcript.jsonl",
          isDirectory: false
        )
      let process = Process()
      process.executableURL = Self.pythonURL(in: bundle)
      process.arguments = [bundle.appendingPathComponent("main.py").path]
      process.environment = environment(
        bundle: bundle,
        executionRoot: executionRoot,
        journal: transcriptURL,
        additional: additionalEnvironment
      )
      process.environment?["OMARCHY_PERFORMANCE_LOG"] = transcriptURL.path + ".performance.jsonl"
      process.currentDirectoryURL = bundle
      let inputPipe = standardInput == nil ? nil : Pipe()
      process.standardInput = inputPipe ?? FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
        if let standardInput, let inputPipe {
          try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
          try inputPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
      } catch {
        throw PinnedAsahiEngineExecutionError.launchFailed
      }
      guard process.terminationReason == .exit,
        process.terminationStatus == 0
      else {
        if let journal, let retryIdentity,
          isRecoveryAuthorizationRetryEligible(
            journal: journal,
            identity: retryIdentity
          )
        {
          throw PinnedAsahiEngineExecutionError
            .recoveryAuthorizationFailed
        }
        throw PinnedAsahiEngineExecutionError.engineExited(
          process.terminationStatus
        )
      }
      return try readTranscript(transcriptURL)
    }

    private func isRecoveryAuthorizationRetryEligible(
      journal: URL,
      identity: RecoveryRetryIdentity
    ) -> Bool {
      guard let transcript = try? readTranscript(journal) else {
        return false
      }
      var evidence = [String: Data]()
      for identifier in [
        "apfs-target-prepared",
        "stub-and-esp-installed",
      ] {
        guard
          let value = try? readCheckpointEvidence(
            journal: journal,
            identifier: identifier
          )
        else {
          return false
        }
        evidence[identifier] = value
      }
      return RecoveryAuthorizationRetryCheckpoint.isEligible(
        transcript: transcript,
        planDigest: identity.planDigest,
        deviceIdentifier: identity.deviceIdentifier,
        storeIdentifier: identity.storeIdentifier,
        checkpointEvidence: evidence
      )
    }

    private func readCheckpointEvidence(
      journal: URL,
      identifier: String
    ) throws -> Data {
      let evidenceURL = URL(
        fileURLWithPath: "\(journal.path).\(identifier).evidence"
      )
      let descriptor = Darwin.open(
        evidenceURL.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      defer { Darwin.close(descriptor) }

      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_mode & 0o077 == 0,
        status.st_uid == expectedFileOwnerID(),
        status.st_size > 0,
        status.st_size <= 1_048_576
      else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      let handle = FileHandle(
        fileDescriptor: descriptor,
        closeOnDealloc: false
      )
      guard let data = try handle.readToEnd(),
        data.count == Int(status.st_size)
      else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      return data
    }

    private func installEnvironment(
      package: ImportedEngineHandoffPackage,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation
    ) -> [String: String] {
      var environment = [
        "OMARCHY_ENGINE_MODE": operation.rawValue,
        "OMARCHY_ENGINE_REQUEST": package.requestURL.path,
        "OMARCHY_ENGINE_IDENTITY": package.identityURL.path,
        "OMARCHY_ENGINE_METADATA": package.metadataURL.path,
        "OMARCHY_ENGINE_PAYLOAD": package.payloadURL.path,
        "OMARCHY_ENGINE_BINDING_DIGEST": package.bindingDigest,
        "OMARCHY_ENGINE_PLAN_DIGEST": package.planDigest,
        "OMARCHY_MACHINE_OWNER": authorization.username,
        "DISTRO": "Omarchy MX Mac",
        "DISTRO_DOCS": "https://omarchy.org/manual/",
      ]
      if let repairManifestURL = package.repairManifestURL {
        environment["OMARCHY_ENGINE_REPAIR_MANIFEST"] =
          repairManifestURL.path
      }
      return environment
    }

    private func repairEnvironment(
      mode: String,
      repairManifestURL: URL?,
      additional: [String: String] = [:]
    ) -> [String: String] {
      var environment = additional
      environment["OMARCHY_ENGINE_MODE"] = mode
      if let repairManifestURL {
        environment["OMARCHY_ENGINE_REPAIR_MANIFEST"] =
          repairManifestURL.path
      }
      return environment
    }

    private func environment(
      bundle: URL,
      executionRoot: URL,
      journal: URL,
      additional: [String: String]
    ) -> [String: String] {
      var values = [
        "HOME": executionRoot.path,
        "TMPDIR": executionRoot.path,
        "PATH": [
          bundle.appendingPathComponent("bin").path,
          "/usr/bin",
          "/bin",
          "/usr/sbin",
          "/sbin",
        ].joined(separator: ":"),
        "LC_ALL": "C",
        "LANG": "C",
        "DYLD_LIBRARY_PATH": bundle.appendingPathComponent(
          "Frameworks/Python.framework/Versions/Current/lib"
        ).path,
        "DYLD_FRAMEWORK_PATH": bundle.appendingPathComponent(
          "Frameworks"
        ).path,
        "SSL_CERT_FILE": bundle.appendingPathComponent(
          "Frameworks/Python.framework/Versions/Current/etc/openssl/cert.pem"
        ).path,
        "OMARCHY_ENGINE_JOURNAL": journal.path,
      ]
      values.merge(additional) { _, new in new }
      return values
    }

    private func validateArchive(
      _ archive: URL,
      expectedDigest: String?,
      expectedSizeBytes: UInt64?
    ) throws {
      let descriptor = Darwin.open(
        archive.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else {
        throw PinnedAsahiEngineExecutionError.unsafeArchive
      }
      defer { Darwin.close(descriptor) }

      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_mode & 0o022 == 0,
        status.st_size > 0,
        status.st_size <= Self.maximumArchiveBytes
      else {
        throw PinnedAsahiEngineExecutionError.unsafeArchive
      }

      if let expectedSizeBytes {
        guard UInt64(status.st_size) == expectedSizeBytes else {
          throw PinnedAsahiEngineExecutionError.archiveSizeMismatch
        }
      }
      if let expectedDigest {
        let handle = FileHandle(
          fileDescriptor: descriptor,
          closeOnDealloc: false
        )
        var hasher = SHA256()
        var bytesRead: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576),
          !chunk.isEmpty
        {
          hasher.update(data: chunk)
          bytesRead += UInt64(chunk.count)
        }
        guard bytesRead == UInt64(status.st_size) else {
          throw PinnedAsahiEngineExecutionError.unsafeArchive
        }
        let digest = SHA256Digest.prefixedHex(hasher.finalize())
        guard digest == expectedDigest else {
          throw PinnedAsahiEngineExecutionError.archiveDigestMismatch
        }
      }
    }

    private func validateArchiveEntries(_ archive: URL) throws {
      let output = Pipe()
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
      process.arguments = ["-tzf", archive.path]
      process.environment = Self.systemEnvironment
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
      } catch {
        throw PinnedAsahiEngineExecutionError.launchFailed
      }
      let listing = try output.fileHandleForReading.readToEnd() ?? Data()
      process.waitUntilExit()
      guard process.terminationReason == .exit,
        process.terminationStatus == 0,
        !listing.isEmpty,
        listing.count <= 8_388_608,
        let names = String(data: listing, encoding: .utf8)
      else {
        throw PinnedAsahiEngineExecutionError.unsafeArchiveEntry
      }

      for name in names.split(
        separator: "\n",
        omittingEmptySubsequences: true
      ) {
        guard !name.isEmpty,
          name.utf8.count <= 1_024,
          !name.hasPrefix("/")
        else {
          throw PinnedAsahiEngineExecutionError.unsafeArchiveEntry
        }
        let components = name.split(
          separator: "/",
          omittingEmptySubsequences: false
        )
        guard !components.contains("..") else {
          throw PinnedAsahiEngineExecutionError.unsafeArchiveEntry
        }
      }
    }

    private func extract(_ archive: URL, into bundle: URL) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
      process.arguments =
        extractionOptions + [
          "-xzf", archive.path, "-C", bundle.path, "--no-same-owner",
          "--no-same-permissions",
        ]
      process.environment = Self.systemEnvironment
      process.currentDirectoryURL = bundle
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
        process.waitUntilExit()
      } catch {
        throw PinnedAsahiEngineExecutionError.launchFailed
      }
      guard process.terminationReason == .exit,
        process.terminationStatus == 0
      else {
        throw PinnedAsahiEngineExecutionError.extractionFailed(
          process.terminationStatus
        )
      }
    }

    private func validateExtractedBundle(_ bundle: URL) throws {
      guard
        let enumerator = FileManager.default.enumerator(
          at: bundle,
          includingPropertiesForKeys: nil,
          options: [],
          errorHandler: { _, _ in false }
        )
      else {
        throw PinnedAsahiEngineExecutionError.invalidBundle
      }

      while let url = enumerator.nextObject() as? URL {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
          throw PinnedAsahiEngineExecutionError.invalidBundle
        }
        let kind = status.st_mode & S_IFMT
        if kind == S_IFREG || kind == S_IFDIR {
          guard status.st_mode & 0o022 == 0 else {
            throw PinnedAsahiEngineExecutionError.invalidBundle
          }
        } else if kind == S_IFLNK {
          try validateSymlink(url, beneath: bundle)
        } else {
          throw PinnedAsahiEngineExecutionError.invalidBundle
        }
      }

      try requireRegularFile(
        bundle.appendingPathComponent("main.py"),
        executable: false
      )
      try requireRegularFile(Self.pythonURL(in: bundle), executable: true)
    }

    private func validateSymlink(_ url: URL, beneath bundle: URL) throws {
      let target = try FileManager.default.destinationOfSymbolicLink(
        atPath: url.path
      )
      guard !target.isEmpty, !target.hasPrefix("/") else {
        throw PinnedAsahiEngineExecutionError.invalidBundle
      }
      var depth =
        url.deletingLastPathComponent().pathComponents.count
        - bundle.pathComponents.count
      for component in target.split(
        separator: "/",
        omittingEmptySubsequences: false
      ) {
        if component == ".." {
          depth -= 1
          guard depth >= 0 else {
            throw PinnedAsahiEngineExecutionError.invalidBundle
          }
        } else if component != "." && !component.isEmpty {
          depth += 1
        }
      }
    }

    private func requireRegularFile(
      _ url: URL,
      executable: Bool
    ) throws {
      var status = stat()
      guard lstat(url.path, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_mode & 0o022 == 0,
        !executable || status.st_mode & 0o111 != 0
      else {
        throw PinnedAsahiEngineExecutionError.invalidBundle
      }
    }

    private func preparePersistentJournal(
      for package: ImportedEngineHandoffPackage
    ) throws -> URL {
      guard
        let bindingDigest = SHA256Digest(
          rawValue: package.bindingDigest
        )
      else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      let identifier = bindingDigest.hexadecimal

      let directory = package.packageURL
        .deletingLastPathComponent()
        .appendingPathComponent("execution-journals", isDirectory: true)
      if !FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700]
        )
      }
      try validateJournalDirectory(directory)

      let journal = directory.appendingPathComponent("\(identifier).jsonl")
      let descriptor = Darwin.open(
        journal.path,
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
      )
      guard descriptor >= 0 else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_mode & 0o077 == 0,
        status.st_uid == expectedFileOwnerID(),
        status.st_size <= Self.maximumTranscriptBytes
      else {
        Darwin.close(descriptor)
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      Darwin.close(descriptor)
      return journal
    }

    private func validateJournalDirectory(_ directory: URL) throws {
      var status = stat()
      guard lstat(directory.path, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFDIR,
        status.st_mode & 0o077 == 0,
        status.st_uid == expectedFileOwnerID()
      else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
    }

    private func readTranscript(_ journal: URL) throws -> Data {
      let descriptor = Darwin.open(
        journal.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      defer { Darwin.close(descriptor) }

      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_mode & 0o077 == 0,
        status.st_size > 0,
        status.st_size <= Self.maximumTranscriptBytes
      else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      let handle = FileHandle(
        fileDescriptor: descriptor,
        closeOnDealloc: false
      )
      guard let data = try handle.readToEnd(),
        data.count == Int(status.st_size),
        data.last == 0x0A
      else {
        throw PinnedAsahiEngineExecutionError.unsafeTranscript
      }
      return data
    }

    private func writePrivateJSON<T: Encodable>(
      _ value: T,
      to destination: URL
    ) throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(value)
      try data.write(to: destination, options: .withoutOverwriting)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o400],
        ofItemAtPath: destination.path
      )
    }

    private static func pythonURL(in bundle: URL) -> URL {
      bundle.appendingPathComponent(
        "Frameworks/Python.framework/Versions/3.13/bin/python3.13"
      )
    }

    private static let systemEnvironment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "LC_ALL": "C",
      "LANG": "C",
    ]

    private struct RecoveryRetryIdentity {
      let planDigest: String
      let deviceIdentifier: String
      let storeIdentifier: String

      init(package: ImportedEngineHandoffPackage) {
        planDigest = package.planDigest
        deviceIdentifier = package.deviceIdentifier
        storeIdentifier = package.storeIdentifier
      }
    }
  }
#endif
