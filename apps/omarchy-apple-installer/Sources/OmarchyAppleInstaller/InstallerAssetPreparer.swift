#if os(macOS)
  import Foundation

  public struct InstallerAssetPreparationRequest: Sendable {
    public let host: AppleSiliconHostInspection
    public let catalogPayload: Data
    public let catalogSignature: Data
    public let trustRoot: AppOwnedTrustRoot
    public let validationTime: Date
    public let previouslyAcceptedCatalog: AcceptedCatalogIdentity?
    public let installerVersion: InstallerVersion?
    public let stagingDirectory: URL

    public init(
      host: AppleSiliconHostInspection,
      catalogPayload: Data,
      catalogSignature: Data,
      trustRoot: AppOwnedTrustRoot,
      validationTime: Date,
      previouslyAcceptedCatalog: AcceptedCatalogIdentity? = nil,
      installerVersion: InstallerVersion? = nil,
      stagingDirectory: URL
    ) {
      self.host = host
      self.catalogPayload = catalogPayload
      self.catalogSignature = catalogSignature
      self.trustRoot = trustRoot
      self.validationTime = validationTime
      self.previouslyAcceptedCatalog = previouslyAcceptedCatalog
      self.installerVersion = installerVersion
      self.stagingDirectory = stagingDirectory
    }
  }

  public struct PreparedInstallerAssets: Sendable {
    public let catalogIdentity: AcceptedCatalogIdentity
    public let installer: PinnedInstallerRecord
    public let engine: StagedInstallerArtifact
    public let metadata: StagedInstallerArtifact
    public let payload: StagedInstallerArtifact
    public let repairManifest: StagedInstallerArtifact?
    public let installerCompatibility: InstallerCompatibility?

    public init(
      catalogIdentity: AcceptedCatalogIdentity,
      installer: PinnedInstallerRecord,
      engine: StagedInstallerArtifact,
      metadata: StagedInstallerArtifact,
      payload: StagedInstallerArtifact,
      repairManifest: StagedInstallerArtifact? = nil,
      installerCompatibility: InstallerCompatibility? = nil
    ) {
      self.catalogIdentity = catalogIdentity
      self.installer = installer
      self.engine = engine
      self.metadata = metadata
      self.payload = payload
      self.repairManifest = repairManifest
      self.installerCompatibility = installerCompatibility
    }
  }

  public enum InstallerAssetPreparationError: Error, Equatable, Sendable {
    case hostBlocked(String)
    case unsupportedDevice(String)
    case deliveryMetadataUnavailable
    case installerOutdated(
      current: InstallerVersion,
      minimum: InstallerVersion,
      downloadURL: URL
    )
  }

  public struct InstallerAssetPreparer: Sendable {
    private static let explicitlyUnsupportedDevices = ["apple,j614s"]

    private let trustCore: AppleInstallerTrustCore
    private let stager: VerifiedArtifactStager

    public init() {
      trustCore = AppleInstallerTrustCore()
      stager = VerifiedArtifactStager()
    }

    init(stager: VerifiedArtifactStager) {
      trustCore = AppleInstallerTrustCore()
      self.stager = stager
    }

    public func prepare(
      _ request: InstallerAssetPreparationRequest,
      progress: ArtifactStagingProgressHandler? = nil,
      previouslyPrepared: PreparedInstallerAssets? = nil
    ) async throws -> PreparedInstallerAssets {
      let deviceIdentifier = try validateHost(request.host)

      let catalog = try trustCore.validateSupportCatalog(
        payload: request.catalogPayload,
        signature: request.catalogSignature,
        trustRoot: request.trustRoot,
        now: request.validationTime,
        previouslyAccepted: request.previouslyAcceptedCatalog
      )
      if let compatibility = catalog.installerCompatibility,
        let current = request.installerVersion,
        !compatibility.accepts(current)
      {
        throw InstallerAssetPreparationError.installerOutdated(
          current: current,
          minimum: compatibility.minimumVersion,
          downloadURL: compatibility.downloadURL
        )
      }
      guard
        case .admitted(let installer) = catalog.admission(
          for: deviceIdentifier
        )
      else {
        throw InstallerAssetPreparationError.unsupportedDevice(deviceIdentifier)
      }
      guard let delivery = installer.delivery else {
        throw InstallerAssetPreparationError.deliveryMetadataUnavailable
      }
      // Two releases can name an artifact identically (every channel ships an
      // installer_data.json) with different bytes. Staging by release keeps a
      // channel switch from tripping over the previous channel's download.
      let stagingDirectory = try Self.releaseStagingDirectory(
        for: installer,
        in: request.stagingDirectory
      )

      if let previous = previouslyPrepared, previous.installer == installer {
        let artifacts =
          [previous.engine, previous.metadata, previous.payload]
          + (previous.repairManifest.map { [$0] } ?? [])
        let available = artifacts.allSatisfy { staged in
          guard
            staged.fileURL.deletingLastPathComponent().standardizedFileURL
              == stagingDirectory.standardizedFileURL,
            let values = try? staged.fileURL.resourceValues(forKeys: [
              .isRegularFileKey, .fileSizeKey,
            ]),
            values.isRegularFile == true,
            let size = values.fileSize, size >= 0
          else { return false }
          return UInt64(size) == staged.artifact.expectedSizeBytes
        }
        if available {
          // Reuse for planning only. Handoff and root import still verify bytes.
          return PreparedInstallerAssets(
            catalogIdentity: catalog.acceptedIdentity, installer: installer,
            engine: previous.engine, metadata: previous.metadata, payload: previous.payload,
            repairManifest: previous.repairManifest,
            installerCompatibility: catalog.installerCompatibility
          )
        }
      }

      async let engine = stager.stage(
        delivery.engine,
        in: stagingDirectory,
        progress: progress
      )
      async let metadata = stager.stage(
        delivery.metadata,
        in: stagingDirectory,
        progress: progress
      )
      async let payload = stager.stage(
        delivery.payload,
        in: stagingDirectory,
        progress: progress
      )
      async let repairManifest = stageRepairManifest(
        delivery.repairManifest,
        in: stagingDirectory,
        progress: progress
      )

      return PreparedInstallerAssets(
        catalogIdentity: catalog.acceptedIdentity,
        installer: installer,
        engine: try await engine,
        metadata: try await metadata,
        payload: try await payload,
        repairManifest: try await repairManifest,
        installerCompatibility: catalog.installerCompatibility
      )
    }

    static func releaseStagingDirectory(
      for installer: PinnedInstallerRecord,
      in stagingDirectory: URL
    ) throws -> URL {
      let revision = installer.evidenceRevision
      guard revision.range(of: "^[0-9a-z][0-9a-z.-]*$", options: .regularExpression) != nil,
        revision != ".", revision != ".."
      else {
        throw InstallerAssetPreparationError.deliveryMetadataUnavailable
      }
      return stagingDirectory.appendingPathComponent(revision, isDirectory: true)
    }

    private func stageRepairManifest(
      _ artifact: PinnedInstallerArtifact?,
      in stagingDirectory: URL,
      progress: ArtifactStagingProgressHandler?
    ) async throws -> StagedInstallerArtifact? {
      guard let artifact else {
        return nil
      }
      return try await stager.stage(
        artifact,
        in: stagingDirectory,
        progress: progress
      )
    }

    func validateHost(
      _ host: AppleSiliconHostInspection
    ) throws -> String {
      if case .blocked(let reason) = host.eligibility {
        throw InstallerAssetPreparationError.hostBlocked(reason)
      }
      let deviceIdentifier = host.identity.deviceIdentifier
      guard !Self.explicitlyUnsupportedDevices.contains(deviceIdentifier) else {
        throw InstallerAssetPreparationError.unsupportedDevice(deviceIdentifier)
      }
      return deviceIdentifier
    }
  }
#endif
