import AppKit
import Foundation
import OmarchyAppleInstallerTrustCore
import OmarchyInstallerUXCore

/// The real installer environment.
///
/// It owns the trust objects the screens must never see — the host inspection,
/// the engine transcripts, the prepared plan, the review, the approval, and the
/// release configuration — and hands the UI only render-only display models.
/// Approval is always rebuilt from the retained review, never from a display
/// model, and no credential is ever stored here.
final class LiveInstallerEnvironment: InstallerEnvironment, @unchecked Sendable {
  private let lock = NSLock()
  private let helperService =
    InstallerHelperServiceManager.preinstalledSystemDaemon()

  private var hostInspection: AppleSiliconHostInspection?
  private var engineInspection: ValidatedEngineTranscript?
  private var engineInspectionTranscript: Data?
  private var engineInspectionFailure: String?
  private var planReview: InstallerPlanReview?
  private var preparedPlan: PreparedInstallerPlanExecution?
  private var planApproval: CandidateBoundPlanApproval?
  private var releaseConfiguration: InstallerReleaseConfiguration?

  // MARK: Fail-closed gates

  var installationBlocked: Bool {
    lock.withLock {
      guard let hostInspection else {
        return true
      }
      if case .blocked = hostInspection.eligibility {
        return true
      }
      return false
    }
  }

  var engineSupported: Bool {
    lock.withLock { engineInspection?.support == .supported }
  }

  var hasApprovedPlan: Bool {
    lock.withLock {
      preparedPlan != nil && planApproval != nil && releaseConfiguration != nil
    }
  }

  var helperStatus: HelperDisplay {
    HelperDisplay(status: helperService.status)
  }

  // MARK: Inspection

  func inspect() async throws -> HostDisplay {
    let host = try await Task.detached(priority: .userInitiated) {
      try AppleSiliconHostInspector().inspect()
    }.value

    var engine: ValidatedEngineTranscript?
    var transcript: Data?
    var engineFailure: String?
    do {
      let inspection = try await EngineInspectionRunner().inspect()
      guard
        inspection.validated.deviceIdentifier == host.identity.deviceIdentifier
      else {
        engineFailure = PlainLanguage.engineIdentityMismatch
        throw InstallerAppError.hostChanged
      }
      engine = inspection.validated
      transcript = inspection.transcript
    } catch ValidationEngineArtifactError.unavailable {
      engineFailure = PlainLanguage.engineUnavailable
    } catch InstallerAppError.hostChanged {
      // engineFailure already set above.
    } catch {
      engineFailure =
        "Pinned engine inspection failed validation (\(String(describing: error))). Installation remains locked."
    }

    lock.withLock {
      hostInspection = host
      engineInspection = engine
      engineInspectionTranscript = transcript
      engineInspectionFailure = engineFailure
      planReview = nil
      preparedPlan = nil
      planApproval = nil
      releaseConfiguration = nil
    }

    return display(host: host, engine: engine, engineFailure: engineFailure)
  }

  // MARK: Plan preparation

  func preparePlan(
    omarchyBytes: UInt64?,
    progress: @escaping @Sendable (AssetProgressUpdate) -> Void
  ) async throws -> PlanPreparationDisplay {
    let (host, hasTranscript) = lock.withLock {
      let retained = (hostInspection, engineInspectionTranscript != nil)
      planReview = nil
      preparedPlan = nil
      planApproval = nil
      releaseConfiguration = nil
      return retained
    }

    guard let host, hasTranscript else {
      throw InstallerAppError.inspectionRequired
    }

    progress(AssetProgressUpdate(stage: .fetchingCatalog))

    let configuration = try InstallerReleaseConfigurationLocator()
      .loadFromMainBundle()
    let workspace = try installerWorkspace()
    let channel = ReleaseChannelPreference()
      .resolve(descriptorDefault: configuration.defaultChannel)
    let catalogStore = AcceptedCatalogIdentityStore(
      directory: workspace.state,
      channel: channel
    )
    let previouslyAcceptedCatalog = try catalogStore.load()
    let validationTime = Date()

    let collector = StagingProgressCollector(publish: progress)
    let release = try await InstallerReleaseAssetCoordinator()
      .prepareRelease(
        InstallerReleasePreparationRequest(
          host: host,
          configuration: configuration,
          channel: channel,
          validationTime: validationTime,
          previouslyAcceptedCatalog: previouslyAcceptedCatalog,
          installerVersion: InstallerVersion.current(),
          stagingDirectory: workspace.staging
        ),
        progress: { event in
          collector.record(event)
        }
      )
    try catalogStore.store(release.assets.catalogIdentity)

    progress(
      AssetProgressUpdate(stage: .inspectingEngine, rows: collector.rows())
    )

    let stagedEngine = release.assets.engine
    let archive = try PinnedAsahiEngineArchive(
      fileURL: stagedEngine.fileURL,
      expectedDigest: stagedEngine.artifact.expectedDigest,
      expectedSizeBytes: stagedEngine.artifact.expectedSizeBytes
    )
    let signedInspection = try await EngineInspectionRunner().inspect(archive)
    guard
      signedInspection.validated.deviceIdentifier
        == host.identity.deviceIdentifier,
      signedInspection.validated.support == .supported,
      let inventory = signedInspection.validated.inventory
    else {
      throw InstallerPlanPreparationError.unsupportedDevice(
        host.identity.deviceIdentifier
      )
    }

    progress(AssetProgressUpdate(stage: .planning, rows: collector.rows()))

    // Existing installs are never replaced or joined: report them and let
    // the session refuse.
    let existing = Self.existingInstalls(in: signedInspection.validated)
    if !existing.isEmpty {
      return .existingInstallChoice(existing)
    }
    let recommendation = try InstallerAllocationRecommendation(
      inventory: inventory,
      targetBytes: omarchyBytes ?? InstallerAllocationRecommendation.balancedTargetBytes
    )
    let candidate = recommendation.candidate
    let requestedLengthBytes = recommendation.requestedLengthBytes

    let prepared = try await InstallerPlanPreparationCoordinator()
      .prepareExecution(
        InstallerPlanPreparationRequest(
          host: host,
          release: release,
          configuration: configuration,
          inspectionTranscript: signedInspection.transcript,
          candidate: candidate,
          requestedLengthBytes: requestedLengthBytes,
          validationTime: validationTime,
          previouslyAcceptedCatalog: previouslyAcceptedCatalog,
          scratchDirectory: workspace.scratch
        )
      )

    lock.withLock {
      preparedPlan = prepared
      planReview = prepared.review
      releaseConfiguration = configuration
    }

    return .plan(
      Self.planDisplay(
        review: prepared.review, host: host, recommendation: recommendation,
        release:
          "\(channel.rawValue.uppercased()) · \(release.assets.payload.fileURL.lastPathComponent)"
      ))
  }

  // MARK: Approval

  /// The confirmation is rebuilt field by field from the retained review — the
  /// same values the Exact plan panel rendered — and `approve(confirming:)`
  /// re-checks every one of them.
  func approve() throws {
    let review = lock.withLock { planReview }

    guard let review else {
      throw InstallerAppError.approvalUnavailable
    }
    let confirmation = InstallerOwnerPlanConfirmation(
      bindingDigest: review.identity.bindingDigest,
      planDigest: review.plan.planDigest,
      deviceIdentifier: review.plan.deviceIdentifier,
      storeIdentifier: review.plan.storeIdentifier,
      sourceIdentifier: review.plan.sourceIdentifier,
      offsetBytes: review.plan.offsetBytes,
      lengthBytes: review.plan.lengthBytes,
      requiredHumanSteps: review.plan.requiredHumanSteps
    )
    do {
      let approval = try review.approve(confirming: confirmation)
      lock.withLock { planApproval = approval }
    } catch {
      lock.withLock { planApproval = nil }
      throw error
    }
  }

  func discardApproval() {
    lock.withLock { planApproval = nil }
  }

  // MARK: Helper

  func refreshHelperStatus() -> HelperDisplay {
    helperStatus
  }

  // MARK: Shutdown

  /// The graceful route: the same Apple Event the Apple menu sends. Apps with
  /// unsaved work can still object, and nothing here needs the privileged
  /// helper.
  func requestShutdown() -> Bool {
    let target = NSAppleEventDescriptor(
      bundleIdentifier: "com.apple.loginwindow"
    )
    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kCoreEventClass),
      eventID: AEEventID(kAEShutDown),
      targetDescriptor: target,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    do {
      _ = try event.sendEvent(options: [.noReply], timeout: 3)
      return true
    } catch {
      return false
    }
  }

  // MARK: Execution

  func execute(
    operation: InstallOperationKind,
    authorization: MachineOwnerAuthorization,
    journal: @escaping @Sendable (Data) -> Void
  ) async throws -> CompletionDisplay {
    let (prepared, approval, configuration, host) = lock.withLock {
      (preparedPlan, planApproval, releaseConfiguration, hostInspection)
    }

    guard let prepared, let approval, let configuration, let host else {
      throw InstallerAppError.approvalUnavailable
    }

    // Re-inspection identity match: the Mac that is about to be written to
    // must still be the Mac the plan was bound to.
    let currentHost = try AppleSiliconHostInspector().inspect()
    guard
      currentHost.identity.deviceIdentifier == host.identity.deviceIdentifier
    else {
      throw InstallerAppError.hostChanged
    }

    let workspace = try installerWorkspace()
    let coordinator = InstallerExecutionCoordinator()
    let progress: InstallerExecutionProgress
    switch operation {
    case .install:
      progress = try await coordinator.execute(
        prepared,
        approval: approval,
        configuration: configuration,
        handoffDirectory: workspace.handoff,
        machineOwnerAuthorization: authorization,
        journalProgress: journal
      )
    case .retryRecoveryAuthorization:
      progress = try await coordinator.retryRecoveryAuthorization(
        prepared,
        approval: approval,
        configuration: configuration,
        handoffDirectory: workspace.handoff,
        machineOwnerAuthorization: authorization,
        journalProgress: journal
      )
    }
    return Self.completionDisplay(progress)
  }

  // MARK: Display mapping

  private func display(
    host: AppleSiliconHostInspection,
    engine: ValidatedEngineTranscript?,
    engineFailure: String?
  ) -> HostDisplay {
    let blocked: Bool
    if case .blocked = host.eligibility {
      blocked = true
    } else {
      blocked = false
    }

    return HostDisplay(
      chipAndSpace:
        "\(host.identity.chip) · \(PlainLanguage.bytes(host.storage.containerFreeBytes)) free",
      supported: !blocked && engine?.support == .supported,
      blockingReason: blockingReason(host: host, engineFailure: engineFailure),
      existingInstalls: Self.existingInstalls(in: engine)
    )
  }

  /// Existing Omarchy installs the bundled engine's inventory reports as
  /// replace candidates. Read at the welcome stage, so the installer can
  /// refuse before it fetches the catalog or downloads anything.
  static func existingInstalls(
    in engine: ValidatedEngineTranscript?
  ) -> [ExistingInstallDisplay] {
    guard let inventory = engine?.inventory else {
      return []
    }
    return inventory.candidates
      .filter { $0.kind == "replace" }
      .map { existing in
        ExistingInstallDisplay(
          sourceIdentifier: existing.sourceIdentifier,
          sizeDescription: PlainLanguage.bytes(existing.lengthBytes)
        )
      }
  }

  private func blockingReason(
    host: AppleSiliconHostInspection,
    engineFailure: String?
  ) -> String? {
    if case .blocked(let reason) = host.eligibility {
      return reason
    }
    return engineFailure
  }

  static func planDisplay(
    review: InstallerPlanReview,
    host: AppleSiliconHostInspection,
    recommendation: InstallerAllocationRecommendation,
    release: String
  ) -> PlanDisplay {
    let length = review.plan.lengthBytes
    let total =
      review.plan.candidateKind == "free"
      ? host.storage.containerSizeBytes + recommendation.candidate.lengthBytes
      : max(host.storage.containerSizeBytes, length)

    return PlanDisplay(
      diskTotalBytes: total,
      omarchyBytes: length,
      bindingDigest: review.identity.bindingDigest,
      isResizable: review.plan.candidateKind != "replace",
      minimumBytes: recommendation.minimumBytes,
      maximumBytes: recommendation.maximumBytes,
      releaseDescription: release,
      targetDescription:
        "\(review.plan.storeIdentifier) · \(review.plan.sourceIdentifier) · \(review.plan.candidateKind == "free" ? "Use free space" : "Resize macOS container")",
      fixedMacOSBytes: review.plan.candidateKind == "free" ? host.storage.containerSizeBytes : nil
    )
  }

  static func completionDisplay(
    _ progress: InstallerExecutionProgress
  ) -> CompletionDisplay {
    let handoff: HandoffDisplay?
    switch progress.nextAction {
    case .enterRecovery:
      handoff = HandoffDisplay(
        headline: PlainLanguage.recoveryHeadline,
        steps: PlainLanguage.recoverySteps(for: progress.requiredHumanSteps)
      )
    case .attachInstallationMedia:
      handoff = HandoffDisplay(
        headline: PlainLanguage.mediaHeadline,
        steps: PlainLanguage.recoverySteps(for: progress.requiredHumanSteps)
      )
    default:
      handoff = nil
    }

    return CompletionDisplay(
      nextAction: progress.nextAction,
      headline: progress.nextAction == .verifyInstalledSystem
        ? PlainLanguage.doneHeadline : PlainLanguage.recoveryHeadline,
      subheadline: PlainLanguage.nextActionMessage(progress.nextAction),
      verified: PlainLanguage.doneVerifiedRows,
      handoff: handoff
    )
  }

  // MARK: Workspace

  private func installerWorkspace() throws
    -> (staging: URL, scratch: URL, state: URL, handoff: URL)
  {
    guard
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw InstallerAppError.workspaceUnavailable
    }
    let base = applicationSupport.appendingPathComponent(
      "com.omarchy.mx.installer",
      isDirectory: true
    )
    let staging = base.appendingPathComponent("staging", isDirectory: true)
    let scratch = base.appendingPathComponent("scratch", isDirectory: true)
    let state = base.appendingPathComponent("state", isDirectory: true)
    let handoff = base.appendingPathComponent("handoff", isDirectory: true)
    try createPrivateDirectoryIfMissing(base)
    try createPrivateDirectoryIfMissing(staging)
    try createPrivateDirectoryIfMissing(scratch)
    try createPrivateDirectoryIfMissing(state)
    try createPrivateDirectoryIfMissing(handoff)
    return (staging, scratch, state, handoff)
  }

  private func createPrivateDirectoryIfMissing(_ directory: URL) throws {
    guard !FileManager.default.fileExists(atPath: directory.path) else {
      return
    }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
  }
}

/// Collects `ArtifactStagingProgress` events by role and republishes them as
/// preparing-screen rows.
private final class StagingProgressCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var latest = [String: ArtifactStagingProgress]()
  private let publish: @Sendable (AssetProgressUpdate) -> Void

  init(publish: @escaping @Sendable (AssetProgressUpdate) -> Void) {
    self.publish = publish
  }

  func record(_ event: ArtifactStagingProgress) {
    let snapshot = lock.withLock { () -> [AssetProgressRow] in
      latest[event.role] = event
      return AssetProgressRow.rows(from: latest)
    }
    publish(AssetProgressUpdate(stage: .downloading, rows: snapshot))
  }

  func rows() -> [AssetProgressRow] {
    lock.withLock { AssetProgressRow.rows(from: latest) }
  }
}
