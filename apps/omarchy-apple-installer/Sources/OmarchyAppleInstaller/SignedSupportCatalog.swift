import CryptoKit
import Foundation

public struct PinnedInstallerRecord: Equatable, Sendable {
  public let deviceIdentifier: String
  public let operation: String
  public let asahiInstallerTag: String
  public let asahiInstallerRevision: String
  public let asahiInstallerDataRevision: String
  public let downstreamRevision: String
  public let engineVersion: String?
  public let engineDigest: String
  public let metadataDigest: String
  public let payloadDigest: String
  public let repairManifestDigest: String?
  public let evidenceRevision: String
  public let delivery: PinnedInstallerDelivery?

  public init(
    deviceIdentifier: String,
    operation: String = "install",
    asahiInstallerTag: String,
    asahiInstallerRevision: String,
    asahiInstallerDataRevision: String,
    downstreamRevision: String,
    engineVersion: String?,
    engineDigest: String,
    metadataDigest: String,
    payloadDigest: String,
    repairManifestDigest: String? = nil,
    evidenceRevision: String,
    delivery: PinnedInstallerDelivery?
  ) {
    self.deviceIdentifier = deviceIdentifier
    self.operation = operation
    self.asahiInstallerTag = asahiInstallerTag
    self.asahiInstallerRevision = asahiInstallerRevision
    self.asahiInstallerDataRevision = asahiInstallerDataRevision
    self.downstreamRevision = downstreamRevision
    self.engineVersion = engineVersion
    self.engineDigest = engineDigest
    self.metadataDigest = metadataDigest
    self.payloadDigest = payloadDigest
    self.repairManifestDigest = repairManifestDigest
    self.evidenceRevision = evidenceRevision
    self.delivery = delivery
  }
}

public struct PinnedInstallerDelivery: Equatable, Sendable {
  public let engine: PinnedInstallerArtifact
  public let metadata: PinnedInstallerArtifact
  public let payload: PinnedInstallerArtifact
  public let repairManifest: PinnedInstallerArtifact?

  public init(
    engine: PinnedInstallerArtifact,
    metadata: PinnedInstallerArtifact,
    payload: PinnedInstallerArtifact,
    repairManifest: PinnedInstallerArtifact? = nil
  ) {
    self.engine = engine
    self.metadata = metadata
    self.payload = payload
    self.repairManifest = repairManifest
  }
}

/// Which installer versions a catalog accepts, and where to get a current one.
///
/// The block is optional and additive: a catalog without it places no
/// constraint on the installer.
public struct InstallerCompatibility: Equatable, Sendable {
  public let minimumVersion: InstallerVersion
  public let latestVersion: InstallerVersion
  public let downloadURL: URL

  public init(
    minimumVersion: InstallerVersion,
    latestVersion: InstallerVersion,
    downloadURL: URL
  ) {
    self.minimumVersion = minimumVersion
    self.latestVersion = latestVersion
    self.downloadURL = downloadURL
  }

  public func accepts(_ version: InstallerVersion) -> Bool {
    version >= minimumVersion
  }
}

struct SupportCatalog: Equatable, Sendable {
  static let empty = SupportCatalog(sequence: 0, records: [:])

  let sequence: UInt64
  let installerCompatibility: InstallerCompatibility?
  private let records: [String: PinnedInstallerRecord]

  init(
    sequence: UInt64,
    records: [String: PinnedInstallerRecord],
    installerCompatibility: InstallerCompatibility? = nil
  ) {
    self.sequence = sequence
    self.records = records
    self.installerCompatibility = installerCompatibility
  }

  func record(for deviceIdentifier: String) -> PinnedInstallerRecord? {
    records[deviceIdentifier]
  }
}

public enum SupportCatalogError: Error, Equatable, Sendable {
  case invalidPublicKey
  case invalidSignature
  case invalidPayload
  case unsupportedSchema(Int)
  case invalidSequence
  case duplicateDeviceIdentifier(String)
  case invalidField(String)
  case notYetValid
  case expired
}

struct SignedSupportCatalogVerifier: Sendable {
  func verify(
    payload: Data,
    signature: Data,
    publicKey: Data,
    now: Date
  ) throws -> SupportCatalog {
    let trustRoot: Curve25519.Signing.PublicKey

    do {
      trustRoot = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    } catch {
      throw SupportCatalogError.invalidPublicKey
    }

    guard trustRoot.isValidSignature(signature, for: payload) else {
      throw SupportCatalogError.invalidSignature
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let manifest: Manifest
    do {
      manifest = try decoder.decode(Manifest.self, from: payload)
    } catch {
      throw SupportCatalogError.invalidPayload
    }

    guard [1, 2, 3, 4].contains(manifest.schemaVersion) else {
      throw SupportCatalogError.unsupportedSchema(manifest.schemaVersion)
    }
    guard manifest.sequence > 0 else {
      throw SupportCatalogError.invalidSequence
    }
    if let expiresAt = manifest.expiresAt {
      guard manifest.issuedAt < expiresAt else {
        throw SupportCatalogError.invalidField("expiresAt")
      }
      guard manifest.issuedAt <= now else {
        throw SupportCatalogError.notYetValid
      }
      guard now < expiresAt else {
        throw SupportCatalogError.expired
      }
    } else {
      // Schema 4 catalogs never expire, so a Mac whose clock is behind — one
      // that has not reached a time server yet — must still install. The
      // monotonic sequence is the guard that matters.
      guard manifest.schemaVersion >= 4 else {
        throw SupportCatalogError.invalidField("expiresAt")
      }
    }
    let compatibility = try installerCompatibility(from: manifest.installer)

    var seenDeviceIdentifiers = Set<String>()
    var records = [String: PinnedInstallerRecord]()

    for (index, model) in manifest.models.enumerated() {
      guard seenDeviceIdentifiers.insert(model.deviceIdentifier).inserted else {
        throw SupportCatalogError.duplicateDeviceIdentifier(model.deviceIdentifier)
      }
      guard isDeviceIdentifier(model.deviceIdentifier) else {
        throw SupportCatalogError.invalidField("models[\(index)].deviceIdentifier")
      }
      guard isSemanticVersionTag(model.asahiInstallerTag) else {
        throw SupportCatalogError.invalidField("models[\(index)].asahiInstallerTag")
      }
      guard SHA256Digest(rawValue: model.engineDigest) != nil else {
        throw SupportCatalogError.invalidField("models[\(index)].engineDigest")
      }
      guard SHA256Digest(rawValue: model.metadataDigest) != nil else {
        throw SupportCatalogError.invalidField("models[\(index)].metadataDigest")
      }
      guard SHA256Digest(rawValue: model.payloadDigest) != nil else {
        throw SupportCatalogError.invalidField("models[\(index)].payloadDigest")
      }
      let operation: String
      let repairManifestDigest: String?
      if manifest.schemaVersion == 3 {
        guard model.operation == "repair-installed-system" else {
          throw SupportCatalogError.invalidField(
            "models[\(index)].operation"
          )
        }
        guard let digest = model.repairManifestDigest,
          SHA256Digest(rawValue: digest) != nil
        else {
          throw SupportCatalogError.invalidField(
            "models[\(index)].repairManifestDigest"
          )
        }
        operation = "repair-installed-system"
        repairManifestDigest = digest
      } else {
        operation = "install"
        repairManifestDigest = nil
      }
      guard isGitRevision(model.asahiInstallerRevision) else {
        throw SupportCatalogError.invalidField(
          "models[\(index)].asahiInstallerRevision"
        )
      }
      guard isGitRevision(model.asahiInstallerDataRevision) else {
        throw SupportCatalogError.invalidField(
          "models[\(index)].asahiInstallerDataRevision"
        )
      }
      guard isGitRevision(model.downstreamRevision) else {
        throw SupportCatalogError.invalidField(
          "models[\(index)].downstreamRevision"
        )
      }
      guard isEvidenceRevision(model.evidenceRevision) else {
        throw SupportCatalogError.invalidField(
          "models[\(index)].evidenceRevision"
        )
      }

      let engineVersion: String?
      if manifest.schemaVersion >= 2 {
        guard let candidate = model.engineVersion,
          isEngineVersion(candidate)
        else {
          throw SupportCatalogError.invalidField(
            "models[\(index)].engineVersion"
          )
        }
        engineVersion = candidate
      } else {
        engineVersion = nil
      }

      guard model.status == .enabled else {
        continue
      }

      let delivery = try installerDelivery(
        for: model,
        schemaVersion: manifest.schemaVersion,
        modelIndex: index
      )

      records[model.deviceIdentifier] = PinnedInstallerRecord(
        deviceIdentifier: model.deviceIdentifier,
        operation: operation,
        asahiInstallerTag: model.asahiInstallerTag,
        asahiInstallerRevision: model.asahiInstallerRevision,
        asahiInstallerDataRevision: model.asahiInstallerDataRevision,
        downstreamRevision: model.downstreamRevision,
        engineVersion: engineVersion,
        engineDigest: model.engineDigest,
        metadataDigest: model.metadataDigest,
        payloadDigest: model.payloadDigest,
        repairManifestDigest: repairManifestDigest,
        evidenceRevision: model.evidenceRevision,
        delivery: delivery
      )
    }

    return SupportCatalog(
      sequence: manifest.sequence,
      records: records,
      installerCompatibility: compatibility
    )
  }

  private func installerCompatibility(
    from record: InstallerCompatibilityRecord?
  ) throws -> InstallerCompatibility? {
    guard let record else {
      return nil
    }
    guard let minimum = InstallerVersion(record.minimumVersion) else {
      throw SupportCatalogError.invalidField("installer.minimumVersion")
    }
    guard let latest = InstallerVersion(record.latestVersion) else {
      throw SupportCatalogError.invalidField("installer.latestVersion")
    }
    guard minimum <= latest else {
      throw SupportCatalogError.invalidField("installer.minimumVersion")
    }
    let url = record.downloadURL
    guard url.scheme == "https",
      url.host?.isEmpty == false,
      url.user == nil,
      url.password == nil,
      url.fragment == nil
    else {
      throw SupportCatalogError.invalidField("installer.downloadURL")
    }
    return InstallerCompatibility(
      minimumVersion: minimum,
      latestVersion: latest,
      downloadURL: url
    )
  }

  private func installerDelivery(
    for model: ModelRecord,
    schemaVersion: Int,
    modelIndex: Int
  ) throws -> PinnedInstallerDelivery? {
    guard schemaVersion >= 2 else {
      return nil
    }
    guard let engine = model.engineArtifact,
      let metadata = model.metadataArtifact,
      let payload = model.payloadArtifact
    else {
      throw SupportCatalogError.invalidField(
        "models[\(modelIndex)].artifacts"
      )
    }

    do {
      let repairManifest: PinnedInstallerArtifact?
      if schemaVersion == 3 {
        guard let artifact = model.repairManifestArtifact,
          let digest = model.repairManifestDigest
        else {
          throw SupportCatalogError.invalidField(
            "models[\(modelIndex)].artifacts"
          )
        }
        repairManifest = try artifact.descriptor(
          role: "repair-manifest",
          digest: digest,
          field: "models[\(modelIndex)].repairManifestArtifact"
        )
      } else {
        repairManifest = nil
      }
      return PinnedInstallerDelivery(
        engine: try engine.descriptor(
          role: "engine",
          digest: model.engineDigest,
          field: "models[\(modelIndex)].engineArtifact"
        ),
        metadata: try metadata.descriptor(
          role: "metadata",
          digest: model.metadataDigest,
          field: "models[\(modelIndex)].metadataArtifact"
        ),
        payload: try payload.descriptor(
          role: "payload",
          digest: model.payloadDigest,
          field: "models[\(modelIndex)].payloadArtifact",
          allowsParts: true
        ),
        repairManifest: repairManifest
      )
    } catch let error as SupportCatalogError {
      throw error
    } catch {
      throw SupportCatalogError.invalidField(
        "models[\(modelIndex)].artifacts"
      )
    }
  }

  private func isGitRevision(_ value: String) -> Bool {
    isLowercaseHex(value, count: 40)
  }

  private func isDeviceIdentifier(_ value: String) -> Bool {
    guard value.hasPrefix("apple,") else {
      return false
    }

    let product = value.dropFirst(6)
    return !product.isEmpty
      && product.utf8.allSatisfy { byte in
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122)
      }
  }

  private func isSemanticVersionTag(_ value: String) -> Bool {
    guard value.hasPrefix("v") else {
      return false
    }

    let components = value.dropFirst().split(
      separator: ".",
      omittingEmptySubsequences: false
    )
    return components.count == 3
      && components.allSatisfy { component in
        !component.isEmpty && component.allSatisfy(\.isNumber)
      }
  }

  private func isEvidenceRevision(_ value: String) -> Bool {
    (1...128).contains(value.utf8.count)
      && value.utf8.allSatisfy { byte in
        (byte >= 48 && byte <= 57)
          || (byte >= 97 && byte <= 122)
          || byte == 45
          || byte == 46
      }
  }

  private func isEngineVersion(_ value: String) -> Bool {
    value.hasPrefix("v")
      && (2...128).contains(value.utf8.count)
      && value.utf8.allSatisfy { byte in
        (byte >= 48 && byte <= 57)
          || (byte >= 65 && byte <= 90)
          || (byte >= 97 && byte <= 122)
          || byte == 43
          || byte == 45
          || byte == 46
          || byte == 95
      }
  }

  private func isLowercaseHex(_ value: String, count: Int) -> Bool {
    value.count == count
      && value.allSatisfy { character in
        character.isNumber || ("a"..."f").contains(character)
      }
  }
}

private struct Manifest: Decodable {
  let schemaVersion: Int
  let sequence: UInt64
  let issuedAt: Date
  let expiresAt: Date?
  let installer: InstallerCompatibilityRecord?
  let models: [ModelRecord]
}

private struct InstallerCompatibilityRecord: Decodable {
  let minimumVersion: String
  let latestVersion: String
  let downloadURL: URL
}

private struct ModelRecord: Decodable {
  let deviceIdentifier: String
  let status: ModelStatus
  let operation: String?
  let asahiInstallerTag: String
  let asahiInstallerRevision: String
  let asahiInstallerDataRevision: String
  let downstreamRevision: String
  let engineVersion: String?
  let engineDigest: String
  let metadataDigest: String
  let payloadDigest: String
  let repairManifestDigest: String?
  let evidenceRevision: String
  let engineArtifact: ModelArtifactRecord?
  let metadataArtifact: ModelArtifactRecord?
  let payloadArtifact: ModelArtifactRecord?
  let repairManifestArtifact: ModelArtifactRecord?
}

private struct ModelArtifactRecord: Decodable {
  let sourceURL: URL
  let fileName: String
  let sizeBytes: UInt64
  let parts: [ModelArtifactPartRecord]?

  func descriptor(
    role: String,
    digest: String,
    field: String,
    allowsParts: Bool = false
  ) throws -> PinnedInstallerArtifact {
    var pinnedParts = [PinnedArtifactPart]()
    if let parts {
      guard allowsParts else {
        throw SupportCatalogError.invalidField("\(field).parts")
      }
      guard (2...PinnedInstallerArtifact.maximumPartCount).contains(parts.count)
      else {
        throw SupportCatalogError.invalidField("\(field).parts")
      }
      pinnedParts = try parts.map { part in try part.descriptor() }
    }

    return try PinnedInstallerArtifact(
      role: role,
      sourceURL: sourceURL,
      fileName: fileName,
      expectedDigest: digest,
      expectedSizeBytes: sizeBytes,
      parts: pinnedParts
    )
  }
}

private struct ModelArtifactPartRecord: Decodable {
  let sourceURL: URL
  let fileName: String
  let sizeBytes: UInt64
  let sha256: String

  func descriptor() throws -> PinnedArtifactPart {
    try PinnedArtifactPart(
      sourceURL: sourceURL,
      fileName: fileName,
      expectedDigest: sha256,
      expectedSizeBytes: sizeBytes
    )
  }
}
private enum ModelStatus: String, Decodable {
  case enabled
  case disabled
}
