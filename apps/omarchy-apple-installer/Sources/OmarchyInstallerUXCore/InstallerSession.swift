#if os(macOS)
  import Foundation
  import Observation
  import OmarchyAppleInstallerTrustCore

  public enum InstallerSessionPhase: Equatable, Sendable {
    case inspecting
    case unsupported(FailureDisplay)
    case welcome(HostDisplay)
    /// Omarchy is already on this Mac. The installer never replaces or adds
    /// to an existing install; this is a terminal page with a Close button.
    case existingInstallRefused(host: HostDisplay)
    case preparingPlan(AssetProgressUpdate)
    /// Everything is downloaded and verified; the plan waits for the person to
    /// continue instead of replacing the download screen on its own.
    case planPrepared(PlanDisplay, AssetProgressUpdate)
    case planReview(PlanDisplay, acknowledged: Bool)
    case awaitingInstall(
      PlanDisplay,
      helper: HelperDisplay,
      sheet: CredentialSheetState
    )
    case installing(InstallProgressDisplay)
    case awaitingRecovery(HandoffDisplay)
    case done(CompletionDisplay)
    case failed(FailureDisplay)
  }

  /// The whole installer flow as one guarded state machine.
  ///
  /// It replaces the eleven independent `@State` booleans of the previous view
  /// with a single phase plus the small number of latches that must survive a
  /// phase change (`hasExecutionStarted`, `recoveryRetryAvailable`). Every
  /// action is a guarded no-op unless the current phase allows it, so the
  /// fail-closed gates cannot be reached by an unexpected view event.
  @MainActor
  @Observable
  public final class InstallerSession {
    public private(set) var phase: InstallerSessionPhase = .inspecting

    /// Live per-artifact download progress keyed by role, published from the
    /// stager's handler after a main-actor hop.
    public private(set) var stagingProgress = [String: ArtifactStagingProgress]()
    public private(set) var journal = LiveInstallJournalModel()
    public private(set) var isBusy = false
    private var isExecuting = false
    private var operationID = UUID()
    public private(set) var planRevision = 0
    public private(set) var allocationNotice: String?
    public private(set) var shutdownMessage: String?

    public var isSimulation: Bool { environment.isSimulation }
    public var canInspect: Bool { !isBusy && !isExecuting && !hasExecutionStarted }
    public var canChangeChannel: Bool { canInspect && credentialSheet.context == nil }
    public var canEditPlan: Bool {
      guard case .awaitingInstall = phase else { return false }
      return canInspect && credentialSheet.context == nil
    }

    public func editPlan() {
      guard canEditPlan, case .awaitingInstall(let plan, _, _) = phase else { return }
      environment.discardApproval()
      phase = .planReview(plan, acknowledged: false)
    }

    /// One-shot latch: an approved plan may be submitted for execution once.
    /// Cleared only by the re-inspect / re-prepare reset cascades, plus the one
    /// provable no-work case (the helper rejected the credentials before it
    /// imported the package or started the engine).
    public private(set) var hasExecutionStarted = false
    public private(set) var recoveryRetryAvailable = false

    private let environment: any InstallerEnvironment
    private var retrySheet = CredentialSheetState.hidden
    private var installStartedAt = Date()
    /// The last successfully inspected host, kept so a re-plan that surfaces
    /// an existing install can still name the Mac it refused.
    private var lastHost: HostDisplay?
    private var lastOmarchyBytes: UInt64?
    private var lastPrepared: (plan: PlanDisplay, update: AssetProgressUpdate)?
    /// True while a chosen size is being re-planned; the Plan screen stays
    /// visible with its controls disabled instead of showing the download
    /// screen again.
    private var isReplanning = false

    public init(environment: any InstallerEnvironment) {
      self.environment = environment
    }

    // MARK: Derived state

    public var installationBlocked: Bool {
      if case .unsupported = phase {
        return true
      }
      return environment.installationBlocked
    }

    public var credentialSheet: CredentialSheetState {
      if case .awaitingInstall(_, _, let sheet) = phase {
        return sheet
      }
      return retrySheet
    }

    /// Preserved verbatim from `canStartInstallation`: every conjunct still has
    /// to hold, even though the phase machine already makes some of them
    /// structurally impossible to violate.
    public var canStartInstallation: Bool {
      guard case .awaitingInstall(_, let helper, _) = phase else {
        return false
      }
      return !environment.installationBlocked
        && !isExecuting
        && !hasExecutionStarted
        && environment.engineSupported
        && environment.hasApprovedPlan
        && helper.isEnabled
    }

    /// Preserved verbatim from `canRetryRecoveryAuthorization`.
    public var canRetryRecoveryAuthorization: Bool {
      recoveryRetryAvailable
        && !environment.installationBlocked
        && !isExecuting
        && environment.engineSupported
        && environment.hasApprovedPlan
        && environment.helperStatus.isEnabled
    }

    // MARK: Inspection

    public func inspect() async {
      guard canInspect else { return }
      operationID = UUID()
      resetForInspection()
      phase = .inspecting
      isBusy = true
      defer { isBusy = false }

      do {
        let host = try await environment.inspect()
        if !host.existingInstalls.isEmpty {
          // Refuse before anything is fetched: no catalog, no download.
          lastHost = host
          phase = .existingInstallRefused(host: host)
        } else if host.supported, !environment.installationBlocked {
          lastHost = host
          phase = .welcome(host)
        } else {
          let blockedModel = environment.installationBlocked
          phase = .unsupported(
            FailureDisplay(
              headline: blockedModel
                ? PlainLanguage.blockedHeadline : PlainLanguage.notReadyHeadline,
              plainDetail: blockedModel
                ? PlainLanguage.blockedSubheadline
                : (host.blockingReason ?? PlainLanguage.notReadyDetail),
              technicalDetail: blockedModel ? nil : host.blockingReason,
              remedy: blockedModel ? PlainLanguage.blockedExplainer : nil,
              isBlockedModel: blockedModel,
              device: host
            )
          )
        }
      } catch {
        phase = .unsupported(
          PlainLanguage.failure(for: error)
        )
      }
    }

    // MARK: Plan preparation

    public func continueToPlan() async {
      guard case .welcome(let host) = phase else {
        return
      }
      await preparePlan(host: host)
    }

    /// Every returned plan is reviewed anew, even when the engine clamps to
    /// the old allocation. A revision clears any tentative view value.
    public func replan(omarchyBytes: UInt64) async {
      guard !isBusy && !isExecuting, case .planReview = phase else { return }
      isReplanning = true
      defer { isReplanning = false }
      await preparePlan(host: lastHost, omarchyBytes: omarchyBytes, hold: false)
    }

    private func preparePlan(
      host: HostDisplay?,
      omarchyBytes: UInt64? = nil,
      hold: Bool = true
    ) async {
      guard !isBusy && !isExecuting && !hasExecutionStarted else { return }
      operationID = UUID()
      let currentOperation = operationID
      resetForPlanPreparation()
      lastOmarchyBytes = omarchyBytes
      if !isReplanning {
        phase = .preparingPlan(AssetProgressUpdate(stage: .fetchingCatalog))
      }
      isBusy = true
      defer { isBusy = false }

      do {
        let outcome = try await environment.preparePlan(omarchyBytes: omarchyBytes) {
          [weak self] update in
          Task { @MainActor in
            guard let self, self.operationID == currentOperation else { return }
            self.applyPreparation(update)
          }
        }
        guard operationID == currentOperation else { return }
        switch outcome {
        case .plan(let plan):
          planRevision += 1
          allocationNotice =
            omarchyBytes.map { requested in
              requested == plan.omarchyBytes
                ? nil
                : "The available space allows \(PlainLanguage.bytes(plan.omarchyBytes)), adjusted from \(PlainLanguage.bytes(requested)). Review this allocation before installing."
            } ?? nil
          let lastUpdate: AssetProgressUpdate =
            if case .preparingPlan(let update) = phase {
              update
            } else {
              lastPrepared?.update ?? AssetProgressUpdate(stage: .planning)
            }
          lastPrepared = (plan, lastUpdate)
          phase = hold ? .planPrepared(plan, lastUpdate) : .planReview(plan, acknowledged: false)
        case .existingInstallChoice(let options):
          // Never replace, never install alongside: say what was found and
          // stop. The only way forward is to remove the existing copy first.
          guard let host, !options.isEmpty else {
            // A choice without the host context (or without options) has no
            // safe way forward; require a fresh inspection.
            phase = .failed(
              FailureDisplay(
                headline: PlainLanguage.planChangedBeforeApproval,
                plainDetail: PlainLanguage.inspectionRequired
              )
            )
            return
          }
          phase = .existingInstallRefused(host: host)
        }
      } catch {
        phase = .failed(PlainLanguage.failure(for: error))
      }
    }

    private func applyPreparation(_ update: AssetProgressUpdate) {
      guard case .preparingPlan = phase else {
        return
      }
      for row in update.rows {
        if let existing = stagingProgress[row.role],
          existing.phase == .verified,
          row.phase != .verified
        {
          continue
        }
        stagingProgress[row.role] = ArtifactStagingProgress(
          role: row.role,
          fileName: row.fileName,
          phase: row.phase,
          partIndex: row.partIndex,
          partCount: row.partCount,
          bytesCompleted: row.bytesCompleted,
          totalBytes: row.totalBytes
        )
      }
      phase = .preparingPlan(
        AssetProgressUpdate(
          stage: update.stage,
          rows: AssetProgressRow.rows(from: stagingProgress)
        )
      )
    }

    // MARK: Review and approval

    /// Leave the finished download screen for the plan review. Only valid once
    /// preparation has completed; a no-op in every other phase.
    public func continueToPlanReview() {
      guard case .planPrepared(let plan, _) = phase else {
        return
      }
      phase = .planReview(plan, acknowledged: false)
    }

    public func setAcknowledged(_ value: Bool) {
      guard !isBusy, case .planReview(let plan, _) = phase else {
        return
      }
      phase = .planReview(plan, acknowledged: value)
    }

    public func approve() {
      guard !isBusy && !isExecuting, case .planReview(let plan, let acknowledged) = phase,
        acknowledged
      else {
        return
      }
      do {
        try environment.approve()
        phase = .awaitingInstall(
          plan,
          helper: environment.refreshHelperStatus(),
          sheet: .hidden
        )
      } catch {
        phase = .failed(
          FailureDisplay(
            headline: PlainLanguage.planChangedBeforeApproval,
            plainDetail:
              "Nothing was authorized. The disk must be inspected and planned again.",
            technicalDetail: String(describing: error)
          )
        )
      }
    }

    // MARK: Helper

    public func refreshHelperStatus() {
      guard case .awaitingInstall(let plan, _, let sheet) = phase else {
        return
      }
      phase = .awaitingInstall(
        plan,
        helper: environment.refreshHelperStatus(),
        sheet: sheet
      )
    }

    // MARK: Credential sheet

    /// Called only after the start-installation confirmation dialog.
    public func presentInstallCredentials() {
      guard case .awaitingInstall(let plan, let helper, _) = phase,
        canStartInstallation
      else {
        return
      }
      phase = .awaitingInstall(
        plan,
        helper: helper,
        sheet: .presented(
          CredentialSheetContext(
            kind: .install,
            bindingDigest: plan.bindingDigest
          )
        )
      )
    }

    /// Called only after the recovery-retry confirmation dialog.
    public func presentRecoveryRetryCredentials() {
      guard case .failed(let failure) = phase,
        failure.retryRecoveryAvailable,
        canRetryRecoveryAuthorization
      else {
        return
      }
      retrySheet = .presented(
        CredentialSheetContext(
          kind: .retryRecoveryAuthorization,
          bindingDigest: ""
        )
      )
    }

    public func dismissCredentials() {
      guard !isExecuting else { return }
      retrySheet = .hidden
      guard case .awaitingInstall(let plan, let helper, _) = phase else {
        return
      }
      phase = .awaitingInstall(plan, helper: helper, sheet: .hidden)
    }

    // MARK: Execution

    public func submit(_ authorization: MachineOwnerAuthorization) async {
      guard !isExecuting, let context = credentialSheet.context else {
        return
      }
      switch context.kind {
      case .install:
        guard canStartInstallation else {
          dismissCredentials()
          phase = .failed(
            FailureDisplay(
              headline: PlainLanguage.approvalUnavailable,
              plainDetail:
                "Nothing was authorized. Inspect this Mac and review the plan again."
            )
          )
          return
        }
        hasExecutionStarted = true
      case .retryRecoveryAuthorization:
        guard canRetryRecoveryAuthorization else {
          dismissCredentials()
          phase = .failed(
            FailureDisplay(
              headline: PlainLanguage.retryCheckpointUnavailable,
              plainDetail:
                "Nothing was authorized. The installation remains stopped."
            )
          )
          return
        }
      }

      operationID = UUID()
      let currentOperation = operationID
      let receivedJournal = SessionJournalBuffer()
      let plan = approvedPlan
      let helper = environment.helperStatus
      // The sheet stays up, locked, while the helper checks the credentials.
      // The Install screen only appears once execution really starts (first
      // journal chunk) or the run ends without one.
      if context.kind == .install, let plan {
        phase = .awaitingInstall(plan, helper: helper, sheet: .presented(context.verifying()))
      } else {
        retrySheet = .presented(context.verifying())
      }
      journal.reset()
      installStartedAt = Date()
      isExecuting = true
      defer { isExecuting = false }

      do {
        let completion = try await environment.execute(
          operation: context.kind,
          authorization: authorization,
          journal: { [weak self] chunk in
            receivedJournal.append(chunk)
            Task { @MainActor in
              guard let self, self.operationID == currentOperation else { return }
              self.drainJournal(receivedJournal)
            }
          }
        )
        guard operationID == currentOperation else { return }
        drainJournal(receivedJournal)
        operationID = UUID()
        recoveryRetryAvailable = false
        beginInstallingIfNeeded()
        route(completion)
      } catch {
        drainJournal(receivedJournal)
        operationID = UUID()
        handleExecutionFailure(error, context: context, plan: plan, helper: helper)
      }
    }

    /// Leaves the credential sheet behind and shows the Install screen. Safe
    /// to call more than once.
    private func beginInstallingIfNeeded() {
      if case .installing = phase {
        return
      }
      retrySheet = .hidden
      phase = .installing(journal.display(startedAt: installStartedAt))
    }

    private func handleExecutionFailure(
      _ error: any Error,
      context: CredentialSheetContext,
      plan: PlanDisplay?,
      helper: HelperDisplay
    ) {
      if let submission = error as? EngineXPCSubmissionError,
        submission == .machineOwnerCredentialsRejected
      {
        // The helper validates the machine-owner credentials before it imports
        // the package or starts the engine, so no execution began: this is the
        // only case that releases the one-shot latch, and it reopens the sheet
        // instead of failing the run.
        if context.kind == .install {
          hasExecutionStarted = false
        }
        let rejected = CredentialSheetContext(
          kind: context.kind,
          bindingDigest: context.bindingDigest,
          error: .credentialsRejected
        )
        if context.kind == .install, let plan {
          phase = .awaitingInstall(
            plan,
            helper: helper,
            sheet: .presented(rejected)
          )
        } else {
          retrySheet = .presented(rejected)
          phase = .failed(
            PlainLanguage.failure(
              for: error,
              retryRecoveryAvailable: recoveryRetryAvailable
            )
          )
        }
        return
      }

      beginInstallingIfNeeded()
      recoveryRetryAvailable = RecoveryAuthorizationRetryPolicy.isEligible(
        after: error
      )
      phase = .failed(
        PlainLanguage.failure(
          for: error,
          retryRecoveryAvailable: recoveryRetryAvailable
        )
      )
    }

    /// Retain the handoff even when another app rejects shutdown. A successful
    /// Apple Event dispatch is not proof that macOS has shut down.
    @discardableResult
    public func shutDown() -> Bool {
      guard case .awaitingRecovery = phase else { return false }
      let accepted = environment.requestShutdown()
      shutdownMessage =
        isSimulation
        ? (accepted
          ? "Simulation: shutdown request accepted. This Mac stays on."
          : "Simulation: shutdown failed. The instructions remain available.")
        : (accepted
          ? "Shutdown requested. If another app cancels it, use Apple menu → Shut Down when ready."
          : "Could not request shutdown. Save your work, then choose Apple menu → Shut Down. Keep these instructions for the next step.")
      return accepted
    }

    private func route(_ completion: CompletionDisplay) {
      switch completion.nextAction {
      case .enterRecovery, .attachInstallationMedia:
        if let handoff = completion.handoff {
          phase = .awaitingRecovery(handoff)
        } else {
          phase = .done(completion)
        }
      case .verifyInstalledSystem, .continueInstallation:
        phase = .done(completion)
      case .manualRecovery:
        phase = .failed(
          FailureDisplay(
            headline: "The installation stopped safely",
            plainDetail: PlainLanguage.nextActionMessage(.manualRecovery),
            remedy: "Review the last trusted checkpoint before continuing."
          )
        )
      }
    }

    private func drainJournal(_ buffer: SessionJournalBuffer) {
      for chunk in buffer.takeAll() { consumeJournal(chunk) }
    }

    private func consumeJournal(_ chunk: Data) {
      if credentialSheet.context?.isVerifying == true {
        // The helper accepted the credentials and the engine has started.
        beginInstallingIfNeeded()
      }
      guard case .installing = phase else {
        return
      }
      journal.consume(chunk)
      phase = .installing(journal.display(startedAt: installStartedAt))
    }

    private var approvedPlan: PlanDisplay? {
      guard case .awaitingInstall(let plan, _, _) = phase else {
        return nil
      }
      return plan
    }

    // MARK: Reset cascades

    /// Mirrors the field resets of `inspectThisMac()`: no approval, plan,
    /// progress, latch, or credential state may survive a re-inspection.
    private func resetForInspection() {
      environment.discardApproval()
      shutdownMessage = nil
      allocationNotice = nil
      stagingProgress = [:]
      journal.reset()
      retrySheet = .hidden
      hasExecutionStarted = false
      recoveryRetryAvailable = false
      isExecuting = false
      lastHost = nil
    }

    /// Mirrors the field resets of `prepareSignedPlan()`.
    private func resetForPlanPreparation() {
      environment.discardApproval()
      stagingProgress = [:]
      journal.reset()
      retrySheet = .hidden
      hasExecutionStarted = false
      recoveryRetryAvailable = false
      isExecuting = false
    }
  }
  /// Receipt is synchronous even when UI delivery needs a main-actor hop.
  /// Draining at completion preserves the final checkpoint before the reply.
  private final class SessionJournalBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    func append(_ chunk: Data) { lock.withLock { chunks.append(chunk) } }
    func takeAll() -> [Data] {
      lock.withLock {
        defer { chunks.removeAll(keepingCapacity: true) }
        return chunks
      }
    }
  }
#endif
