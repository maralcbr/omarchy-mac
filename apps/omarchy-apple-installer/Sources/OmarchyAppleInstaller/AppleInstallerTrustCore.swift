import CryptoKit
import Foundation

public struct AppleInstallerTrustCore: Sendable {
  public init() {}

  public func validateEngineTranscript(
    _ transcript: Data
  ) throws -> ValidatedEngineTranscript {
    let envelopes = try EngineTranscriptDecoder().decode(transcript)
    var inspection: EngineInspectionMessage?
    var inventory: ValidatedEngineInventory?
    var plan: ValidatedEnginePlan?
    var checkpoints = [ValidatedEngineCheckpoint]()
    var completion: EngineCompletionOutcome?

    for envelope in envelopes {
      switch envelope.message {
      case .inspection(let message):
        inspection = message
      case .inventory(let message):
        inventory = ValidatedEngineInventory(
          layoutDigest: message.layoutDigest,
          systemStoreIdentifier: message.systemStoreIdentifier,
          candidates: message.candidates.map {
            ValidatedEngineCandidate(
              kind: $0.kind,
              sourceIdentifier: $0.sourceIdentifier,
              offsetBytes: $0.offsetBytes,
              lengthBytes: $0.lengthBytes,
              minimumInstallBytes: $0.minimumInstallBytes,
              minimumContainerBytes: $0.minimumContainerBytes,
              identityDigest: $0.identityDigest
            )
          }
        )
      case .plan(let message):
        plan = ValidatedEnginePlan(
          planDigest: message.planDigest,
          deviceIdentifier: message.deviceIdentifier,
          storeIdentifier: message.storeIdentifier,
          layoutDigest: message.layoutDigest,
          candidateKind: message.candidateKind,
          sourceIdentifier: message.sourceIdentifier,
          offsetBytes: message.offsetBytes,
          lengthBytes: message.lengthBytes,
          engineVersion: message.engineVersion,
          engineDigest: message.engineDigest,
          metadataDigest: message.metadataDigest,
          payloadDigest: message.payloadDigest,
          repairManifestDigest: message.repairManifestDigest,
          requiredHumanSteps: message.requiredHumanSteps
        )
      case .checkpoint(let message):
        checkpoints.append(
          ValidatedEngineCheckpoint(
            identifier: message.identifier,
            phase: message.phase,
            evidenceDigest: message.evidenceDigest
          )
        )
      case .completion(let message):
        completion = EngineCompletionOutcome(rawValue: message.outcome)
      case .event:
        break
      }
    }

    guard
      let inspection,
      let support = EngineSupport(rawValue: inspection.support)
    else {
      throw EngineContractError.invalidMessage(1)
    }

    return ValidatedEngineTranscript(
      deviceIdentifier: inspection.deviceIdentifier,
      support: support,
      inventory: inventory,
      plan: plan,
      checkpoints: checkpoints,
      completion: completion
    )
  }

  public func validateSupportCatalog(
    payload: Data,
    signature: Data,
    trustRoot: AppOwnedTrustRoot,
    now: Date,
    previouslyAccepted: AcceptedCatalogIdentity? = nil
  ) throws -> ValidatedSupportCatalog {
    let catalog = try SignedSupportCatalogVerifier().verify(
      payload: payload,
      signature: signature,
      publicKey: trustRoot.rawRepresentation,
      now: now
    )
    let payloadDigest = SHA256Digest(hashing: payload).rawValue
    let candidate = try AcceptedCatalogIdentity(
      sequence: catalog.sequence,
      payloadDigest: payloadDigest
    )

    if let previouslyAccepted {
      guard candidate.sequence >= previouslyAccepted.sequence else {
        throw SupportCatalogSequenceError.rollback(
          stored: previouslyAccepted.sequence,
          candidate: candidate.sequence
        )
      }
      guard
        candidate.sequence != previouslyAccepted.sequence
          || candidate.payloadDigest == previouslyAccepted.payloadDigest
      else {
        throw SupportCatalogSequenceError.sequenceReuse(candidate.sequence)
      }
    }

    return ValidatedSupportCatalog(
      catalog: catalog,
      acceptedIdentity: candidate
    )
  }
}

public enum EngineSupport: String, Equatable, Sendable {
  case supported
  case unsupported
}

public enum EngineCompletionOutcome: String, Equatable, Sendable {
  case awaitingRecovery = "awaiting_recovery"
  case awaitingMedia = "awaiting_media"
  case installed
  case manualRecoveryRequired = "manual_recovery_required"
}

public struct ValidatedEngineTranscript: Equatable, Sendable {
  public let deviceIdentifier: String
  public let support: EngineSupport
  public let inventory: ValidatedEngineInventory?
  public let plan: ValidatedEnginePlan?
  public let checkpoints: [ValidatedEngineCheckpoint]
  public let completion: EngineCompletionOutcome?
}

public struct ValidatedEngineInventory: Equatable, Sendable {
  public let layoutDigest: String
  public let systemStoreIdentifier: String
  public let candidates: [ValidatedEngineCandidate]
}

public struct ValidatedEngineCandidate: Equatable, Sendable {
  public let kind: String
  public let sourceIdentifier: String
  public let offsetBytes: UInt64
  public let lengthBytes: UInt64
  public let minimumInstallBytes: UInt64
  public let minimumContainerBytes: UInt64
  public let identityDigest: String?

  public init(
    kind: String,
    sourceIdentifier: String,
    offsetBytes: UInt64,
    lengthBytes: UInt64,
    minimumInstallBytes: UInt64,
    minimumContainerBytes: UInt64,
    identityDigest: String? = nil
  ) {
    self.kind = kind
    self.sourceIdentifier = sourceIdentifier
    self.offsetBytes = offsetBytes
    self.lengthBytes = lengthBytes
    self.minimumInstallBytes = minimumInstallBytes
    self.minimumContainerBytes = minimumContainerBytes
    self.identityDigest = identityDigest
  }
}

public struct ValidatedEnginePlan: Equatable, Sendable {
  public let planDigest: String
  public let deviceIdentifier: String
  public let storeIdentifier: String
  public let layoutDigest: String
  public let candidateKind: String
  public let sourceIdentifier: String
  public let offsetBytes: UInt64
  public let lengthBytes: UInt64
  public let engineVersion: String
  public let engineDigest: String
  public let metadataDigest: String
  public let payloadDigest: String
  public let repairManifestDigest: String?
  public let requiredHumanSteps: [String]
}

public struct ValidatedEngineCheckpoint: Equatable, Sendable {
  public let identifier: String
  public let phase: String
  public let evidenceDigest: String
}

public enum ModelAdmission: Equatable, Sendable {
  case admitted(PinnedInstallerRecord)
  case unsupported(deviceIdentifier: String)
}

public struct ValidatedSupportCatalog: Sendable {
  public let acceptedIdentity: AcceptedCatalogIdentity
  private let catalog: SupportCatalog

  fileprivate init(
    catalog: SupportCatalog,
    acceptedIdentity: AcceptedCatalogIdentity
  ) {
    self.catalog = catalog
    self.acceptedIdentity = acceptedIdentity
  }

  public var sequence: UInt64 {
    acceptedIdentity.sequence
  }

  public var installerCompatibility: InstallerCompatibility? {
    catalog.installerCompatibility
  }

  public func admission(for deviceIdentifier: String) -> ModelAdmission {
    guard let record = catalog.record(for: deviceIdentifier) else {
      return .unsupported(deviceIdentifier: deviceIdentifier)
    }
    return .admitted(record)
  }
}

public struct AcceptedCatalogIdentity: Equatable, Sendable {
  public let format: Int
  public let sequence: UInt64
  public let payloadDigest: String

  public init(sequence: UInt64, payloadDigest: String) throws {
    guard sequence > 0, SHA256Digest(rawValue: payloadDigest) != nil else {
      throw SupportCatalogSequenceError.invalidStoredIdentity
    }
    format = 1
    self.sequence = sequence
    self.payloadDigest = payloadDigest
  }

}

public enum SupportCatalogSequenceError: Error, Equatable, Sendable {
  case invalidStoredIdentity
  case rollback(stored: UInt64, candidate: UInt64)
  case sequenceReuse(UInt64)
}
