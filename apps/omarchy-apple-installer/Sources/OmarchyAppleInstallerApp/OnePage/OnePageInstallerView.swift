import AppKit
import OmarchyAppleInstallerTrustCore
import OmarchyInstallerUXCore
import SwiftUI

/// Version 2 of the installer: one page. The wordmark on top, this Mac in a
/// line, then whatever the moment needs — a download bar, the disk split, an
/// install bar, the Recovery steps — and one primary action underneath.
/// The trust chain and the session are untouched; only the presentation is
/// flattened.
struct OnePageInstallerView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var session: InstallerSession
  @State private var showsShutdownConfirmation = false
  @State private var showsRecoveryRetryConfirmation = false
  /// The last host seen, so the header stays on the page through the phases
  /// that no longer carry it.
  @State private var host: HostDisplay?
  /// Which channel this Mac reads. Owned by the scene so the banner always
  /// names the channel the next preparation will actually fetch.
  let channel: ReleaseChannel

  init(
    environment: any InstallerEnvironment,
    channel: ReleaseChannel = ReleaseChannelPreference().resolve(
      descriptorDefault: .stable
    )
  ) {
    _session = State(initialValue: InstallerSession(environment: environment))
    self.channel = channel
  }

  var body: some View {
    VStack(spacing: 0) {
      OmarchyWordmark()
        .frame(maxWidth: 400)
        .padding(.top, 30)
        .padding(.bottom, 20)

      header
        .padding(.bottom, 26)

      if !centresStage {
        VStack(alignment: .leading, spacing: 14) {
          stage
        }
        .frame(maxWidth: 560)
      }

      Spacer(minLength: 16)

      HStack(spacing: 16) {
        actions
      }
      .padding(.bottom, 28)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 40)
    .overlay {
      if centresStage {
        VStack(alignment: .leading, spacing: 14) {
          stage
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 40)
      }
    }
    .foregroundStyle(OmarchyTheme.text)
    .background(OmarchyTheme.window)
    .focusEffectDisabled()
    .task {
      await session.inspect()
    }
    .onChange(of: channel) { _, _ in
      // Switching channel discards anything already planned: the new channel
      // may name a different release entirely.
      Task { await session.inspect() }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        session.refreshHelperStatus()
      }
    }
    .onChange(of: session.phase, initial: true) { _, phase in
      remember(phase)
      // One page has no "everything is ready" stop: go straight to the plan.
      if case .planPrepared = phase {
        session.continueToPlanReview()
      }
    }
    .sheet(isPresented: credentialSheetBinding) {
      if let context = session.credentialSheet.context {
        CredentialSheet(
          context: context,
          onCancel: { session.dismissCredentials() },
          onSubmit: { authorization in
            Task { await session.submit(authorization) }
          }
        )
      }
    }
    .sheet(isPresented: $showsShutdownConfirmation) {
      ConfirmationSheet(
        title: PlainLanguage.shutdownConfirmationTitle,
        message: PlainLanguage.shutdownConfirmationBody,
        action: PlainLanguage.shutdownConfirmationAction,
        onConfirm: {
          showsShutdownConfirmation = false
          session.shutDown()
          NSApplication.shared.terminate(nil)
        },
        onCancel: { showsShutdownConfirmation = false }
      )
    }
    .sheet(isPresented: $showsRecoveryRetryConfirmation) {
      ConfirmationSheet(
        title: PlainLanguage.recoveryRetryConfirmationTitle,
        message: PlainLanguage.recoveryRetryConfirmationBody,
        action: PlainLanguage.recoveryRetryConfirmationAction,
        onConfirm: {
          showsRecoveryRetryConfirmation = false
          session.presentRecoveryRetryCredentials()
        },
        onCancel: { showsRecoveryRetryConfirmation = false }
      )
    }
  }

  // MARK: Header — this Mac in one line

  @ViewBuilder
  private var header: some View {
    if let host {
      HStack(spacing: 12) {
        Text(host.chipAndSpace)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(OmarchyTheme.secondaryText)
        if isBlocked {
          StatusBadge(text: PlainLanguage.blockedBadge, kind: .blocked)
        } else {
          StatusBadge(text: PlainLanguage.supportedBadge, kind: .ok)
        }
        if channel != .stable {
          StatusBadge(text: PlainLanguage.badge(for: channel), kind: .ok)
        }
      }
      .lineLimit(1)
    } else {
      Text(PlainLanguage.inspectingHeadline)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(OmarchyTheme.secondaryText)
    }
  }

  /// Only the Recovery steps sit in the exact middle of the window (drawn as
  /// an overlay so the header and button don't skew them); everything else
  /// hugs the header.
  private var centresStage: Bool {
    if case .awaitingRecovery = session.phase {
      return true
    }
    return false
  }

  private var isBlocked: Bool {
    switch session.phase {
    case .unsupported, .existingInstallRefused:
      return true
    default:
      return false
    }
  }

  // MARK: The middle of the page

  @ViewBuilder
  private var stage: some View {
    switch session.phase {
    case .inspecting:
      statusPanel(title: PlainLanguage.inspectingSubheadline)

    case .unsupported(let failure):
      messagePanel(
        headline: failure.headline,
        detail: failure.plainDetail,
        remedy: failure.remedy,
        technical: failure.technicalDetail,
        isError: false
      )

    case .welcome:
      Text(PlainLanguage.checkSubheadline)
        .font(.system(size: 14))
        .foregroundStyle(OmarchyTheme.secondaryText)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)

    case .existingInstallRefused:
      existingInstallRefusedPanel()

    case .preparingPlan(let update), .planPrepared(_, let update):
      DownloadPanel(update: update)

    case .planReview(let plan, let acknowledged):
      DiskSplitPanel(
        plan: plan,
        editable: plan.isResizable,
        isBusy: session.isBusy,
        onSizeChosen: { bytes in Task { await session.replan(omarchyBytes: bytes) } }
      )
      acknowledgement(acknowledged)

    case .awaitingInstall(let plan, let helper, _):
      DiskSplitPanel(plan: plan, editable: false, isBusy: false, onSizeChosen: { _ in })
      if !helper.isEnabled {
        helperNote
      }

    case .installing(let progress):
      InstallPanel(progress: progress)

    case .awaitingRecovery(let handoff):
      recoveryPanel(handoff)

    case .done(let completion):
      donePanel(completion)

    case .failed(let failure):
      messagePanel(
        headline: failure.headline,
        detail: failure.plainDetail,
        remedy: failure.remedy,
        technical: failure.technicalDetail,
        isError: true
      )
    }
  }

  // MARK: The one row of buttons

  @ViewBuilder
  private var actions: some View {
    switch session.phase {
    case .inspecting, .preparingPlan, .planPrepared:
      EmptyView()

    case .unsupported:
      Button(PlainLanguage.checkAgain) { Task { await session.inspect() } }
        .omarchySecondaryButton()
        .disabled(session.isBusy)

    case .welcome:
      Button(PlainLanguage.checkContinue) { Task { await session.continueToPlan() } }
        .omarchyPrimaryButton()
        .disabled(session.isBusy)
        .keyboardShortcut(.defaultAction)

    case .existingInstallRefused:
      Button(PlainLanguage.closeInstaller) { NSApplication.shared.terminate(nil) }
        .omarchyPrimaryButton()
        .keyboardShortcut(.defaultAction)

    case .planReview(_, let acknowledged):
      Button(PlainLanguage.planInstall) {
        // Approve the exact plan and go straight to the password. If the
        // helper is not ready the page stays here and says so.
        session.approve()
        if session.canStartInstallation {
          session.presentInstallCredentials()
        }
      }
      .omarchyPrimaryButton()
      .disabled(!acknowledged || session.isBusy)
      .keyboardShortcut(.defaultAction)

    case .awaitingInstall:
      Button(PlainLanguage.planInstall) { session.presentInstallCredentials() }
        .omarchyPrimaryButton()
        .disabled(!session.canStartInstallation)
        .keyboardShortcut(.defaultAction)

    case .installing:
      Text(PlainLanguage.installWarning)
        .font(OmarchyTheme.caption.weight(.medium))
        .foregroundStyle(OmarchyTheme.accent)

    case .awaitingRecovery:
      Button(PlainLanguage.recoveryShutDown) { showsShutdownConfirmation = true }
        .omarchyPrimaryButton()
        .keyboardShortcut(.defaultAction)

    case .done:
      Button(PlainLanguage.startOver) { Task { await session.inspect() } }
        .omarchySecondaryButton()

    case .failed(let failure):
      Button(PlainLanguage.startOver) { Task { await session.inspect() } }
        .omarchySecondaryButton()
      if failure.retryRecoveryAvailable {
        Button(PlainLanguage.retry) { showsRecoveryRetryConfirmation = true }
          .omarchyPrimaryButton()
          .disabled(!session.canRetryRecoveryAuthorization)
          .keyboardShortcut(.defaultAction)
      } else if let url = failure.actionURL, let title = failure.actionTitle {
        Button(title) { NSWorkspace.shared.open(url) }
          .omarchyPrimaryButton()
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  // MARK: Pieces

  private func statusPanel(title: String) -> some View {
    Panel {
      VStack(alignment: .leading, spacing: 12) {
        Text(title)
          .font(.system(size: 13.5, weight: .medium))
          .foregroundStyle(OmarchyTheme.secondaryText)
        ProgressTrack(fraction: nil, height: 14)
      }
      .padding(.vertical, 4)
    }
  }

  private func messagePanel(
    headline: String, detail: String, remedy: String?, technical: String?, isError: Bool
  ) -> some View {
    Panel {
      VStack(alignment: .leading, spacing: 8) {
        Text(headline)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(isError ? OmarchyTheme.danger : OmarchyTheme.text)
        Text(detail)
          .font(OmarchyTheme.body)
          .foregroundStyle(OmarchyTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        if let remedy {
          Text(remedy)
            .font(OmarchyTheme.body)
            .foregroundStyle(OmarchyTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
        }
        if let technical {
          TechnicalDetailText(text: technical)
            .padding(.top, 4)
        }
      }
      .padding(.vertical, 2)
    }
  }

  private func existingInstallRefusedPanel() -> some View {
    Panel {
      Text(PlainLanguage.existingInstallHeadline)
        .font(.system(size: 16, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
    }
  }

  /// The tick and its text. Both are inert while a re-plan runs so a tick
  /// cannot land between the drag and the new plan.
  private func acknowledgement(_ acknowledged: Bool) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Toggle(
        "",
        isOn: Binding(get: { acknowledged }, set: { session.setAcknowledged($0) })
      )
      .labelsHidden()
      .toggleStyle(.checkbox)
      .controlSize(.large)
      .tint(OmarchyTheme.accent)
      .accessibilityLabel(PlainLanguage.planAcknowledgement)
      Text(PlainLanguage.planAcknowledgement)
        .font(.system(size: 13.5, weight: .medium))
        .foregroundStyle(OmarchyTheme.accent)
        .fixedSize(horizontal: false, vertical: true)
        .onTapGesture { session.setAcknowledged(!acknowledged) }
      Spacer(minLength: 0)
    }
    .disabled(session.isBusy)
    .padding(.horizontal, 4)
    .padding(.top, 4)
  }

  private var helperNote: some View {
    HStack(spacing: 10) {
      Image(systemName: "lock.shield")
        .foregroundStyle(OmarchyTheme.caution)
      Text(PlainLanguage.helperNotInstalled)
        .font(OmarchyTheme.caption)
        .foregroundStyle(OmarchyTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 4)
  }

  private func recoveryPanel(_ handoff: HandoffDisplay) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(handoff.headline)
        .font(.system(size: 17, weight: .semibold))
        .padding(.bottom, 4)
      ForEach(handoff.steps) { step in
        RecoveryStepRow(step: step)
      }
    }
  }

  private func donePanel(_ completion: CompletionDisplay) -> some View {
    Panel {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 20))
            .foregroundStyle(OmarchyTheme.accent)
          Text(completion.headline)
            .font(.system(size: 16, weight: .semibold))
        }
        Text(completion.subheadline)
          .font(OmarchyTheme.body)
          .foregroundStyle(OmarchyTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        FactGrid(rows: completion.verified, labelWidth: 118)
          .padding(.top, 6)
      }
    }
  }

  // MARK: Plumbing

  private var credentialSheetBinding: Binding<Bool> {
    Binding(
      get: { session.credentialSheet.context != nil },
      set: { presented in
        if !presented {
          session.dismissCredentials()
        }
      }
    )
  }

  private func remember(_ phase: InstallerSessionPhase) {
    switch phase {
    case .welcome(let seen):
      host = seen
    case .existingInstallRefused(let seen):
      host = seen
    case .unsupported(let failure):
      host = failure.device
    case .inspecting:
      host = nil
    default:
      break
    }
  }
}

// MARK: - The download bar

/// One bar for the OS package download; later stages (engine checks,
/// planning) keep the last position instead of resetting.
private struct DownloadPanel: View {
  let update: AssetProgressUpdate

  @State private var lastCompleted: UInt64 = 0
  @State private var lastTotal: UInt64 = 0

  private var package: AssetProgressRow? {
    update.rows.first { $0.role == "payload" } ?? update.rows.first
  }

  var body: some View {
    Panel {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text(title)
            .font(.system(size: 13.5, weight: .medium))
          Spacer(minLength: 8)
          if let accessory {
            Text(accessory)
              .font(OmarchyTheme.caption.monospacedDigit())
              .foregroundStyle(OmarchyTheme.secondaryText)
          }
        }
        ProgressTrack(fraction: fraction, height: 18)
      }
      .padding(.vertical, 4)
    }
    .onChange(of: update, initial: true) { _, _ in
      if let package, package.totalBytes > 0 {
        lastCompleted = package.bytesCompleted
        lastTotal = package.totalBytes
      }
    }
  }

  private var title: String {
    update.stage == .downloading
      ? PlainLanguage.downloadingPackagesTitle
      : PlainLanguage.preparingStageTitle(update.stage)
  }

  private var fraction: Double? {
    if update.stage == .downloading, let package, package.totalBytes > 0 {
      return Double(package.bytesCompleted) / Double(package.totalBytes)
    }
    guard lastTotal > 0 else {
      return nil
    }
    return Double(lastCompleted) / Double(lastTotal)
  }

  private var accessory: String? {
    let total = (package?.totalBytes ?? 0) > 0 ? package!.totalBytes : lastTotal
    guard total > 0 else {
      return nil
    }
    let completed = (package?.totalBytes ?? 0) > 0 ? package!.bytesCompleted : lastCompleted
    return "\(PlainLanguage.bytes(completed)) of \(PlainLanguage.bytes(total))"
  }
}

// MARK: - The disk split

/// The disk bar with the draggable divider. Letting go on a new whole-GB
/// size re-plans; the chosen size stays on screen until the new plan lands.
private struct DiskSplitPanel: View {
  let plan: PlanDisplay
  let editable: Bool
  let isBusy: Bool
  let onSizeChosen: (UInt64) -> Void

  @State private var exploredOmarchyGB: Double?

  private static let minimumOmarchyGB: Double = 30

  var body: some View {
    Panel {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          Text("MacOS " + PlainLanguage.bytes(plan.diskTotalBytes - displayedOmarchyBytes))
            .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(OmarchyTheme.accent)
          Spacer(minLength: 8)
          Text("Omarchy " + PlainLanguage.bytes(displayedOmarchyBytes))
            .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(OmarchyTheme.accent)
        }
        DiskBar(
          macOSBytes: plan.diskTotalBytes - displayedOmarchyBytes,
          omarchyBytes: displayedOmarchyBytes,
          onAdjustOmarchyFraction: editable ? { adjust($0) } : nil,
          onCommitOmarchyFraction: editable ? { commit($0) } : nil,
          isFrozen: isBusy
        )
        .transaction { $0.animation = nil }
        if isBusy {
          // A released divider re-plans through the engine, which takes a
          // moment; say so instead of leaving the bar and the tick inert.
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text(PlainLanguage.replanning)
              .font(OmarchyTheme.caption)
              .foregroundStyle(OmarchyTheme.secondaryText)
          }
        } else if editable {
          Text(
            "Drag the divider to choose how much space Omarchy gets (minimum \(Int(Self.minimumOmarchyGB)) GB)"
          )
          .font(OmarchyTheme.caption)
          .foregroundStyle(OmarchyTheme.secondaryText)
        }
      }
      .padding(.vertical, 4)
    }
    .onChange(of: plan.omarchyBytes) { _, _ in
      exploredOmarchyGB = nil
    }
  }

  private var displayedOmarchyBytes: UInt64 {
    guard let exploredOmarchyGB else {
      return plan.omarchyBytes
    }
    return UInt64(exploredOmarchyGB * 1_000_000_000)
  }

  private var maximumOmarchyGB: Double {
    let totalGB = Double(plan.diskTotalBytes) / 1_000_000_000
    return max(Self.minimumOmarchyGB + 10, min(800, (totalGB - 120) / 10 * 10).rounded(.down))
  }

  private func adjust(_ fraction: Double) {
    let totalGB = Double(plan.diskTotalBytes) / 1_000_000_000
    let steppedGB = ((totalGB * fraction) / 10).rounded() * 10
    exploredOmarchyGB = min(maximumOmarchyGB, max(Self.minimumOmarchyGB, steppedGB))
  }

  private func commit(_ fraction: Double) {
    adjust(fraction)
    let chosen = displayedOmarchyBytes
    if chosen != plan.omarchyBytes {
      onSizeChosen(chosen)
    } else {
      exploredOmarchyGB = nil
    }
  }
}

// MARK: - The install bar

/// One bar for the whole installation: every stage counts equally and the
/// active stage keeps moving between journal events. A degraded stream
/// sweeps instead.
private struct InstallPanel: View {
  let progress: InstallProgressDisplay

  private var stageLabel: String {
    let index = progress.stageIndex
    if progress.stageLabels.indices.contains(index) {
      return progress.stageLabels[index]
    }
    return progress.phaseTitle
  }

  private var overallFraction: Double? {
    let count = progress.stageFractions.count
    guard count > 0 else {
      return nil
    }
    let total = progress.stageFractions.reduce(0) { $0 + min(1, max(0, $1)) }
    return min(1, max(0, total / Double(count)))
  }

  var body: some View {
    Panel {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text(stageLabel)
            .font(.system(size: 13.5, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 8)
          TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
            Text(elapsed(at: context.date))
              .font(OmarchyTheme.caption.monospacedDigit())
              .foregroundStyle(OmarchyTheme.secondaryText)
          }
          if let overallFraction {
            Text("\(Int((overallFraction * 100).rounded()))%")
              .font(OmarchyTheme.body.monospacedDigit())
              .foregroundStyle(OmarchyTheme.secondaryText)
          }
        }
        ProgressTrack(fraction: progress.degraded ? nil : overallFraction, height: 18)
        if progress.degraded {
          Text(PlainLanguage.installDegraded)
            .font(OmarchyTheme.caption)
            .foregroundStyle(OmarchyTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.vertical, 4)
    }
  }

  private func elapsed(at date: Date) -> String {
    let seconds = max(0, Int(date.timeIntervalSince(progress.startedAt)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
