#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore

  /// Everything a screen renders, derived once by the environment from the
  /// retained trust objects. Display models are render-only: no approval,
  /// confirmation, or execution value is ever rebuilt from them.
  public struct HostDisplay: Equatable, Sendable {
    /// The header line: chip and free space, e.g. "Apple M1 Pro · 464 GB free".
    public let chipAndSpace: String
    public let supported: Bool
    /// Why this Mac cannot install right now, when `supported` is false.
    public let blockingReason: String?
    /// Omarchy installs the inspection found on the disk. Known before any
    /// download, from the bundled validation engine's inventory; the session
    /// refuses to go further when this is not empty.
    public let existingInstalls: [ExistingInstallDisplay]

    public init(
      chipAndSpace: String,
      supported: Bool,
      blockingReason: String? = nil,
      existingInstalls: [ExistingInstallDisplay] = []
    ) {
      self.chipAndSpace = chipAndSpace
      self.supported = supported
      self.blockingReason = blockingReason
      self.existingInstalls = existingInstalls
    }
  }

  public struct PlanFactRow: Equatable, Sendable, Identifiable {
    public let label: String
    public let value: String
    public let isMonospaced: Bool

    public var id: String { label }

    public init(label: String, value: String, isMonospaced: Bool = false) {
      self.label = label
      self.value = value
      self.isMonospaced = isMonospaced
    }
  }

  /// One existing Omarchy install the pinned engine found on this Mac.
  public struct ExistingInstallDisplay: Equatable, Sendable, Identifiable {
    public let sourceIdentifier: String
    public let sizeDescription: String

    public var id: String { sourceIdentifier }

    public init(sourceIdentifier: String, sizeDescription: String) {
      self.sourceIdentifier = sourceIdentifier
      self.sizeDescription = sizeDescription
    }
  }

  /// Plan preparation either yields a reviewable plan or reports the
  /// existing installs it found, which the session refuses. Nothing is
  /// approved or executed from either value.
  public enum PlanPreparationDisplay: Equatable, Sendable {
    case plan(PlanDisplay)
    case existingInstallChoice([ExistingInstallDisplay])
  }

  public struct PlanDisplay: Equatable, Sendable {
    public let diskTotalBytes: UInt64
    public let omarchyBytes: UInt64
    public let bindingDigest: String
    public let minimumBytes: UInt64
    public let maximumBytes: UInt64
    public let releaseDescription: String
    public let targetDescription: String
    public let fixedMacOSBytes: UInt64?
    /// Whether the user may choose Omarchy's size. A replace plan removes an
    /// existing install and reuses its exact extent, so there is nothing to
    /// drag; showing a divider there invites a re-plan the engine refuses.
    public let isResizable: Bool

    public init(
      diskTotalBytes: UInt64,
      omarchyBytes: UInt64,
      bindingDigest: String,
      isResizable: Bool = true,
      minimumBytes: UInt64? = nil,
      maximumBytes: UInt64? = nil,
      releaseDescription: String = "Verified release",
      targetDescription: String = "Internal storage",
      fixedMacOSBytes: UInt64? = nil
    ) {
      self.diskTotalBytes = diskTotalBytes
      self.omarchyBytes = omarchyBytes
      self.bindingDigest = bindingDigest
      self.minimumBytes = minimumBytes ?? omarchyBytes
      self.maximumBytes = maximumBytes ?? omarchyBytes
      self.releaseDescription = releaseDescription
      self.targetDescription = targetDescription
      self.fixedMacOSBytes = fixedMacOSBytes
      self.isResizable = isResizable && self.minimumBytes < self.maximumBytes
    }
  }

  extension PlanDisplay {
    public func macOSBytes(for allocation: UInt64) -> UInt64 {
      fixedMacOSBytes ?? (diskTotalBytes - min(diskTotalBytes, allocation))
    }
    public func unallocatedBytes(for allocation: UInt64) -> UInt64 {
      let remaining = diskTotalBytes - min(diskTotalBytes, macOSBytes(for: allocation))
      return remaining - min(remaining, allocation)
    }
  }

  public struct HelperDisplay: Equatable, Sendable {
    public let status: InstallerHelperServiceStatus

    /// The pre-installed system daemon is reachable, so installation may run.
    public var isEnabled: Bool { status == .enabled }

    public init(status: InstallerHelperServiceStatus) {
      self.status = status
    }
  }

  /// One artifact row on the preparing screen, fed by
  /// `ArtifactStagingProgress` events keyed by role.
  public struct AssetProgressRow: Equatable, Sendable, Identifiable {
    public let role: String
    public let fileName: String
    public let bytesCompleted: UInt64
    public let totalBytes: UInt64
    public let phase: ArtifactStagingProgress.Phase
    public let partIndex: Int?
    public let partCount: Int?

    public var id: String { role }

    public init(
      role: String,
      fileName: String,
      bytesCompleted: UInt64,
      totalBytes: UInt64,
      phase: ArtifactStagingProgress.Phase,
      partIndex: Int? = nil,
      partCount: Int? = nil
    ) {
      self.role = role
      self.fileName = fileName
      self.bytesCompleted = bytesCompleted
      self.totalBytes = totalBytes
      self.phase = phase
      self.partIndex = partIndex
      self.partCount = partCount
    }

    public init(_ progress: ArtifactStagingProgress) {
      self.init(
        role: progress.role,
        fileName: progress.fileName,
        bytesCompleted: progress.bytesCompleted,
        totalBytes: progress.totalBytes,
        phase: progress.phase,
        partIndex: progress.partIndex,
        partCount: progress.partCount
      )
    }

    /// The rows for a set of staging events keyed by role, in role order.
    public static func rows(
      from progress: [String: ArtifactStagingProgress]
    ) -> [AssetProgressRow] {
      progress.values
        .sorted { $0.role < $1.role }
        .map(AssetProgressRow.init)
    }
  }

  public struct AssetProgressUpdate: Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
      case fetchingCatalog
      case downloading
      case inspectingEngine
      case planning
    }

    public let stage: Stage
    public let rows: [AssetProgressRow]

    public init(stage: Stage, rows: [AssetProgressRow] = []) {
      self.stage = stage
      self.rows = rows
    }
  }

  public struct JournalFeedLine: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
      case event
      case checkpoint
      case completion
    }

    public let id: Int
    public let kind: Kind
    public let text: String

    public init(id: Int, kind: Kind, text: String) {
      self.id = id
      self.kind = kind
      self.text = text
    }
  }

  public struct InstallProgressDisplay: Equatable, Sendable {
    public let phaseTitle: String
    public let stageIndex: Int
    public let stageFractions: [Double]
    public let stageLabels: [String]
    public let feed: [JournalFeedLine]
    public let degraded: Bool
    public let startedAt: Date

    public init(
      phaseTitle: String,
      stageIndex: Int,
      stageFractions: [Double],
      stageLabels: [String],
      feed: [JournalFeedLine],
      degraded: Bool,
      startedAt: Date
    ) {
      self.phaseTitle = phaseTitle
      self.stageIndex = stageIndex
      self.stageFractions = stageFractions
      self.stageLabels = stageLabels
      self.feed = feed
      self.degraded = degraded
      self.startedAt = startedAt
    }
  }

  public struct RecoveryStep: Equatable, Sendable, Identifiable {
    public let number: Int
    public let title: String

    public var id: Int { number }

    public init(number: Int, title: String) {
      self.number = number
      self.title = title
    }
  }

  public struct HandoffDisplay: Equatable, Sendable {
    public let headline: String
    public let steps: [RecoveryStep]

    public init(headline: String, steps: [RecoveryStep]) {
      self.headline = headline
      self.steps = steps
    }
  }

  public struct CompletionDisplay: Equatable, Sendable {
    public let nextAction: InstallerNextAction
    public let headline: String
    public let subheadline: String
    public let verified: [PlanFactRow]
    public let handoff: HandoffDisplay?

    public init(
      nextAction: InstallerNextAction,
      headline: String,
      subheadline: String,
      verified: [PlanFactRow],
      handoff: HandoffDisplay?
    ) {
      self.nextAction = nextAction
      self.headline = headline
      self.subheadline = subheadline
      self.verified = verified
      self.handoff = handoff
    }
  }

  public struct FailureDisplay: Equatable, Sendable {
    public let headline: String
    public let plainDetail: String
    public let technicalDetail: String?
    public let remedy: String?
    public let retryRecoveryAvailable: Bool
    public let isBlockedModel: Bool
    public let device: HostDisplay?
    /// A page the person should open to get themselves unstuck, when one
    /// exists — today only the current installer download.
    public let actionURL: URL?
    public let actionTitle: String?

    public init(
      headline: String,
      plainDetail: String,
      technicalDetail: String? = nil,
      remedy: String? = nil,
      retryRecoveryAvailable: Bool = false,
      isBlockedModel: Bool = false,
      device: HostDisplay? = nil,
      actionURL: URL? = nil,
      actionTitle: String? = nil
    ) {
      self.headline = headline
      self.plainDetail = plainDetail
      self.technicalDetail = technicalDetail
      self.remedy = remedy
      self.retryRecoveryAvailable = retryRecoveryAvailable
      self.isBlockedModel = isBlockedModel
      self.device = device
      self.actionURL = actionURL
      self.actionTitle = actionTitle
    }
  }

  public enum InstallOperationKind: String, Equatable, Sendable {
    case install
    case retryRecoveryAuthorization
  }

  public enum CredentialSheetError: String, Equatable, Sendable {
    case credentialsRejected
  }

  public struct CredentialSheetContext: Equatable, Sendable {
    public let kind: InstallOperationKind
    public let bindingDigest: String
    public let error: CredentialSheetError?
    /// True while the helper is checking the submitted credentials. The sheet
    /// stays up (fields locked) so a rejection appears in place instead of the
    /// sheet closing, the screen flipping, and the sheet coming back.
    public let isVerifying: Bool

    public init(
      kind: InstallOperationKind,
      bindingDigest: String,
      error: CredentialSheetError? = nil,
      isVerifying: Bool = false
    ) {
      self.kind = kind
      self.bindingDigest = bindingDigest
      self.error = error
      self.isVerifying = isVerifying
    }

    public func verifying() -> CredentialSheetContext {
      CredentialSheetContext(
        kind: kind, bindingDigest: bindingDigest, error: nil, isVerifying: true)
    }
  }

  public enum CredentialSheetState: Equatable, Sendable {
    case hidden
    case presented(CredentialSheetContext)

    public var context: CredentialSheetContext? {
      guard case .presented(let context) = self else {
        return nil
      }
      return context
    }
  }

  /// The single seam between the SwiftUI screens and the trust chain. The live
  /// implementation retains the trust objects (host inspection, prepared plan,
  /// review, approval, release configuration); the preview implementation
  /// replays a recorded journal. Neither ever hands a credential back.
  public protocol InstallerEnvironment: Sendable {
    var isSimulation: Bool { get }
    func inspect() async throws -> HostDisplay
    /// `omarchyBytes` asks the planner for that much space for Omarchy; nil
    /// keeps the balanced default. The engine still clamps the request to the
    /// candidate's real minimum and maximum.
    func preparePlan(
      omarchyBytes: UInt64?,
      progress: @escaping @Sendable (AssetProgressUpdate) -> Void
    ) async throws -> PlanPreparationDisplay
    func approve() throws
    func discardApproval()
    /// Re-reads whether the pre-installed system daemon is present. There is no
    /// registration or approval step — the package installs the helper.
    func refreshHelperStatus() -> HelperDisplay
    func execute(
      operation: InstallOperationKind,
      authorization: MachineOwnerAuthorization,
      journal: @escaping @Sendable (Data) -> Void
    ) async throws -> CompletionDisplay

    /// Fail-closed gates preserved verbatim from the previous view model.
    var installationBlocked: Bool { get }
    var engineSupported: Bool { get }
    var hasApprovedPlan: Bool { get }
    var helperStatus: HelperDisplay { get }

    /// Asks macOS for a graceful shutdown (the Apple menu's Shut Down).
    /// Returns true when the machine is actually going down; the preview
    /// environment and tests return false so nothing powers off.
    func requestShutdown() -> Bool
  }

  extension InstallerEnvironment {
    public var isSimulation: Bool { false }
    public func requestShutdown() -> Bool { false }
  }
#endif
