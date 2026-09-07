#if os(macOS)
  import CryptoKit
  import Darwin
  import Foundation

  public struct PreparedEngineHandoff: Sendable {
    public let packageURL: URL
    public let manifestURL: URL
    public let requestURL: URL
    public let identityURL: URL
    public let engineURL: URL
    public let metadataURL: URL
    public let payloadURL: URL
    public let repairManifestURL: URL?
  }

  public protocol EngineHandoffSubmitting: Sendable {
    func submit(
      _ handoff: PreparedEngineHandoff,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation
    ) async throws -> Data
  }

  public enum ClosedEngineHandoffError: Error, Equatable, Sendable {
    case assetBindingMismatch
    case duplicateArtifactFileName
    case unsafeHandoffDirectory
    case unsafeArtifact(String)
    case artifactSizeMismatch(String)
    case artifactDigestMismatch(String)
  }

  public struct ClosedEngineHandoffProcess: EngineProcessExecuting, Sendable {
    private let assets: PreparedInstallerAssets
    private let handoffDirectory: URL
    private let submitter: any EngineHandoffSubmitting
    private let authorization: MachineOwnerAuthorization
    private let operation: EngineHandoffOperation

    public init(
      assets: PreparedInstallerAssets,
      handoffDirectory: URL,
      submitter: any EngineHandoffSubmitting,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation = .install
    ) {
      self.assets = assets
      self.handoffDirectory = handoffDirectory
      self.submitter = submitter
      self.authorization = authorization
      self.operation = operation
    }

    public func execute(_ invocation: ClosedEngineInvocation) async throws -> Data {
      let handoff = try InstallerPerformance.measure("app_handoff") {
        try ClosedEngineHandoffBuilder().prepare(
          invocation: invocation,
          assets: assets,
          in: handoffDirectory
        )
      }
      defer { try? FileManager.default.removeItem(at: handoff.packageURL) }
      return try await submitter.submit(
        handoff,
        authorization: authorization,
        operation: operation
      )
    }
  }

  private struct ClosedEngineHandoffBuilder {
    private static let reservedFileNames = [
      "manifest.json",
      "request.json",
      "identity.json",
    ]

    func prepare(
      invocation: ClosedEngineInvocation,
      assets: PreparedInstallerAssets,
      in handoffDirectory: URL
    ) throws -> PreparedEngineHandoff {
      try validateBindings(invocation: invocation, assets: assets)
      try ensurePrivateDirectory(handoffDirectory)

      let artifactFileNames =
        [
          assets.engine.artifact.fileName,
          assets.metadata.artifact.fileName,
          assets.payload.artifact.fileName,
        ] + (assets.repairManifest.map { [$0.artifact.fileName] } ?? [])
      guard Set(artifactFileNames).count == artifactFileNames.count,
        Set(artifactFileNames).isDisjoint(
          with: Self.reservedFileNames
        )
      else {
        throw ClosedEngineHandoffError.duplicateArtifactFileName
      }

      let identifier = UUID().uuidString.lowercased()
      let pending = handoffDirectory.appendingPathComponent(
        ".pending-handoff-\(identifier)",
        isDirectory: true
      )
      let package = handoffDirectory.appendingPathComponent(
        "handoff-\(identifier)",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: pending,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      var shouldRemovePending = true
      defer {
        if shouldRemovePending {
          try? FileManager.default.removeItem(at: pending)
        }
      }

      let engineURL = pending.appendingPathComponent(
        assets.engine.artifact.fileName
      )
      let metadataURL = pending.appendingPathComponent(
        assets.metadata.artifact.fileName
      )
      let payloadURL = pending.appendingPathComponent(
        assets.payload.artifact.fileName
      )
      let repairManifestURL = assets.repairManifest.map {
        pending.appendingPathComponent($0.artifact.fileName)
      }
      try copyVerified(assets.engine, role: "engine", to: engineURL)
      try copyVerified(assets.metadata, role: "metadata", to: metadataURL)
      try copyVerified(assets.payload, role: "payload", to: payloadURL)
      if let staged = assets.repairManifest, let repairManifestURL {
        try copyVerified(
          staged,
          role: "repair-manifest",
          to: repairManifestURL
        )
      }

      let requestURL = pending.appendingPathComponent("request.json")
      let identityURL = pending.appendingPathComponent("identity.json")
      let manifestURL = pending.appendingPathComponent("manifest.json")
      try writePrivateJSON(
        EngineExecutionRequest(invocation: invocation),
        to: requestURL
      )
      try writePrivateJSON(
        EngineExecutionIdentity(invocation: invocation),
        to: identityURL
      )
      try writePrivateJSON(
        EngineHandoffManifest(invocation: invocation, assets: assets),
        to: manifestURL
      )

      try FileManager.default.moveItem(at: pending, to: package)
      shouldRemovePending = false
      return PreparedEngineHandoff(
        packageURL: package,
        manifestURL: package.appendingPathComponent("manifest.json"),
        requestURL: package.appendingPathComponent("request.json"),
        identityURL: package.appendingPathComponent("identity.json"),
        engineURL: package.appendingPathComponent(
          assets.engine.artifact.fileName
        ),
        metadataURL: package.appendingPathComponent(
          assets.metadata.artifact.fileName
        ),
        payloadURL: package.appendingPathComponent(
          assets.payload.artifact.fileName
        ),
        repairManifestURL: assets.repairManifest.map {
          package.appendingPathComponent($0.artifact.fileName)
        }
      )
    }

    private func validateBindings(
      invocation: ClosedEngineInvocation,
      assets: PreparedInstallerAssets
    ) throws {
      guard invocation.catalogIdentity == assets.catalogIdentity,
        invocation.pinnedInstaller == assets.installer,
        invocation.plan.engineDigest == assets.engine.artifact.expectedDigest,
        invocation.plan.metadataDigest == assets.metadata.artifact.expectedDigest,
        invocation.plan.payloadDigest == assets.payload.artifact.expectedDigest,
        invocation.plan.repairManifestDigest
          == assets.repairManifest?.artifact.expectedDigest,
        let delivery = invocation.pinnedInstaller.delivery,
        delivery.engine == assets.engine.artifact,
        delivery.metadata == assets.metadata.artifact,
        delivery.payload == assets.payload.artifact,
        delivery.repairManifest == assets.repairManifest?.artifact,
        invocation.pinnedInstaller.repairManifestDigest
          == invocation.plan.repairManifestDigest,
        (invocation.pinnedInstaller.operation == "repair-installed-system"
          && invocation.plan.candidateKind == "repair"
          && assets.repairManifest != nil)
          || (invocation.pinnedInstaller.operation == "install"
            && invocation.plan.candidateKind != "repair"
            && assets.repairManifest == nil)
      else {
        throw ClosedEngineHandoffError.assetBindingMismatch
      }
    }

    private func ensurePrivateDirectory(_ directory: URL) throws {
      var status = stat()
      guard lstat(directory.path, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFDIR,
        status.st_mode & 0o077 == 0
      else {
        throw ClosedEngineHandoffError.unsafeHandoffDirectory
      }
    }

    private func copyVerified(
      _ staged: StagedInstallerArtifact,
      role: String,
      to destination: URL
    ) throws {
      let sourceDescriptor = Darwin.open(
        staged.fileURL.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
      )
      guard sourceDescriptor >= 0 else {
        throw ClosedEngineHandoffError.unsafeArtifact(role)
      }
      defer { Darwin.close(sourceDescriptor) }

      var sourceStatus = stat()
      guard fstat(sourceDescriptor, &sourceStatus) == 0,
        (sourceStatus.st_mode & S_IFMT) == S_IFREG,
        sourceStatus.st_mode & 0o022 == 0,
        sourceStatus.st_size > 0,
        UInt64(sourceStatus.st_size) == staged.artifact.expectedSizeBytes
      else {
        throw ClosedEngineHandoffError.unsafeArtifact(role)
      }

      if fclonefileat(sourceDescriptor, AT_FDCWD, destination.path, 0) == 0 {
        guard chmod(destination.path, S_IRUSR) == 0 else {
          throw ClosedEngineHandoffError.unsafeArtifact(role)
        }
        let snapshot = try FileHandle(forReadingFrom: destination)
        defer { try? snapshot.close() }
        var hasher = SHA256()
        var size: UInt64 = 0
        while let chunk = try snapshot.read(upToCount: 4 * 1_048_576), !chunk.isEmpty {
          size += UInt64(chunk.count)
          hasher.update(data: chunk)
        }
        guard size == staged.artifact.expectedSizeBytes else {
          throw ClosedEngineHandoffError.artifactSizeMismatch(role)
        }
        guard SHA256Digest.prefixedHex(hasher.finalize()) == staged.artifact.expectedDigest else {
          throw ClosedEngineHandoffError.artifactDigestMismatch(role)
        }
        return
      }
      // Other filesystems retain the verified streaming-copy fallback.
      let destinationDescriptor = Darwin.open(
        destination.path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
        S_IRUSR
      )
      guard destinationDescriptor >= 0 else {
        throw ClosedEngineHandoffError.unsafeArtifact(role)
      }
      var destinationOpen = true
      defer {
        if destinationOpen {
          Darwin.close(destinationDescriptor)
        }
      }

      let sourceHandle = FileHandle(
        fileDescriptor: sourceDescriptor,
        closeOnDealloc: false
      )
      let destinationHandle = FileHandle(
        fileDescriptor: destinationDescriptor,
        closeOnDealloc: false
      )
      var hasher = SHA256()
      var size: UInt64 = 0
      while let chunk = try sourceHandle.read(upToCount: 1_048_576),
        !chunk.isEmpty
      {
        try destinationHandle.write(contentsOf: chunk)
        hasher.update(data: chunk)
        let (updatedSize, overflow) = size.addingReportingOverflow(
          UInt64(chunk.count)
        )
        guard !overflow else {
          throw ClosedEngineHandoffError.artifactSizeMismatch(role)
        }
        size = updatedSize
      }
      try destinationHandle.synchronize()
      try destinationHandle.close()
      destinationOpen = false

      guard size == staged.artifact.expectedSizeBytes else {
        throw ClosedEngineHandoffError.artifactSizeMismatch(role)
      }
      let digest = SHA256Digest.prefixedHex(hasher.finalize())
      guard digest == staged.artifact.expectedDigest else {
        throw ClosedEngineHandoffError.artifactDigestMismatch(role)
      }
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
  }

  private struct EngineExecutionRequest: Encodable {
    let format = 1
    let operation: String
    let planDigest: String
    let deviceIdentifier: String
    let storeIdentifier: String
    let layoutDigest: String
    let candidateKind: String
    let sourceIdentifier: String
    let offsetBytes: UInt64
    let lengthBytes: UInt64
    let engineVersion: String
    let requiredHumanSteps: [String]

    init(invocation: ClosedEngineInvocation) {
      let plan = invocation.plan
      operation = invocation.pinnedInstaller.operation
      planDigest = plan.planDigest
      deviceIdentifier = plan.deviceIdentifier
      storeIdentifier = plan.storeIdentifier
      layoutDigest = plan.layoutDigest
      candidateKind = plan.candidateKind
      sourceIdentifier = plan.sourceIdentifier
      offsetBytes = plan.offsetBytes
      lengthBytes = plan.lengthBytes
      engineVersion = plan.engineVersion
      requiredHumanSteps = plan.requiredHumanSteps
    }

    enum CodingKeys: String, CodingKey {
      case format
      case operation
      case planDigest = "plan_digest"
      case deviceIdentifier = "device_identifier"
      case storeIdentifier = "store_identifier"
      case layoutDigest = "layout_digest"
      case candidateKind = "candidate_kind"
      case sourceIdentifier = "source_identifier"
      case offsetBytes = "offset_bytes"
      case lengthBytes = "length_bytes"
      case engineVersion = "engine_version"
      case requiredHumanSteps = "required_human_steps"
    }
  }

  private struct EngineExecutionIdentity: Encodable {
    let format = 1
    let bindingDigest: String
    let trustRootFingerprint: String
    let catalogSequence: UInt64
    let catalogPayloadDigest: String
    let planDigest: String
    let engineDigest: String
    let metadataDigest: String
    let payloadDigest: String
    let repairManifestDigest: String?

    init(invocation: ClosedEngineInvocation) {
      bindingDigest = invocation.candidateIdentity.bindingDigest
      trustRootFingerprint = invocation.candidateIdentity.trustRootFingerprint
      catalogSequence = invocation.catalogIdentity.sequence
      catalogPayloadDigest = invocation.catalogIdentity.payloadDigest
      planDigest = invocation.plan.planDigest
      engineDigest = invocation.plan.engineDigest
      metadataDigest = invocation.plan.metadataDigest
      payloadDigest = invocation.plan.payloadDigest
      repairManifestDigest = invocation.plan.repairManifestDigest
    }

    enum CodingKeys: String, CodingKey {
      case format
      case bindingDigest = "binding_digest"
      case trustRootFingerprint = "trust_root_fingerprint"
      case catalogSequence = "catalog_sequence"
      case catalogPayloadDigest = "catalog_payload_digest"
      case planDigest = "plan_digest"
      case engineDigest = "engine_digest"
      case metadataDigest = "metadata_digest"
      case payloadDigest = "payload_digest"
      case repairManifestDigest = "repair_manifest_digest"
    }
  }

  private struct EngineHandoffManifest: Encodable {
    let format = 1
    let bindingDigest: String
    let requestFile = "request.json"
    let identityFile = "identity.json"
    let engine: EngineHandoffArtifact
    let metadata: EngineHandoffArtifact
    let payload: EngineHandoffArtifact
    let repairManifest: EngineHandoffArtifact?

    init(
      invocation: ClosedEngineInvocation,
      assets: PreparedInstallerAssets
    ) {
      bindingDigest = invocation.candidateIdentity.bindingDigest
      engine = EngineHandoffArtifact(staged: assets.engine)
      metadata = EngineHandoffArtifact(staged: assets.metadata)
      payload = EngineHandoffArtifact(staged: assets.payload)
      repairManifest = assets.repairManifest.map {
        EngineHandoffArtifact(staged: $0)
      }
    }

    enum CodingKeys: String, CodingKey {
      case format
      case bindingDigest = "binding_digest"
      case requestFile = "request_file"
      case identityFile = "identity_file"
      case engine
      case metadata
      case payload
      case repairManifest = "repair_manifest"
    }
  }

  private struct EngineHandoffArtifact: Encodable {
    let fileName: String
    let digest: String
    let sizeBytes: UInt64

    init(staged: StagedInstallerArtifact) {
      fileName = staged.artifact.fileName
      digest = staged.artifact.expectedDigest
      sizeBytes = staged.artifact.expectedSizeBytes
    }

    enum CodingKeys: String, CodingKey {
      case fileName = "file_name"
      case digest
      case sizeBytes = "size_bytes"
    }
  }
#endif
