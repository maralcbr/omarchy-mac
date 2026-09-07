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
  @State private var contentHeight: CGFloat = 400
  /// Which channel this Mac reads. Owned by the scene so the banner always
  /// names the channel the next preparation will actually fetch.
  let channel: ReleaseChannel
  let onChannelAvailability: (Bool) -> Void
  let onSessionAvailable: (InstallerSession) -> Void

  init(
    environment: any InstallerEnvironment,
    channel: ReleaseChannel = ReleaseChannelPreference().resolve(
      descriptorDefault: .stable
    ),
    onChannelAvailability: @escaping (Bool) -> Void = { _ in },
    onSessionAvailable: @escaping (InstallerSession) -> Void = { _ in }
  ) {
    _session = State(initialValue: InstallerSession(environment: environment))
    self.channel = channel
    self.onChannelAvailability = onChannelAvailability
    self.onSessionAvailable = onSessionAvailable
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        OmarchyWordmark()
          .frame(maxWidth: 400)
          .padding(.top, 24)
          .padding(.bottom, 16)
        header.padding(.bottom, 20)
        VStack(alignment: .leading, spacing: 14) { stage }
          .frame(maxWidth: 560)
        HStack(spacing: 16) { actions }
          .padding(.top, 24)
          .padding(.bottom, 24)
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 40)
      .background {
        GeometryReader { geometry in
          Color.clear.preference(key: InstallerContentHeight.self, value: geometry.size.height)
        }
      }
    }
    .frame(height: min(contentHeight, 680))
    .onPreferenceChange(InstallerContentHeight.self) { height in
      if height > 0 { contentHeight = height }
    }
    .foregroundStyle(OmarchyTheme.text)
    .background(OmarchyTheme.window)
    .onChange(of: session.canChangeChannel, initial: true) { _, available in
      onChannelAvailability(available)
    }
    .task {
      onSessionAvailable(session)
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
          isSimulation: session.isSimulation,
          approvedSize: approvedSize,
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
        StatusBadge(text: channel == .rc ? "Release candidate" : "Stable", kind: .ok)
      }
      .lineLimit(1)
    } else {
      Text(PlainLanguage.inspectingHeadline)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(OmarchyTheme.secondaryText)
    }
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
        onSizeChosen: { bytes in
          session.setAcknowledged(false)
          Task { await session.replan(omarchyBytes: bytes) }
        },
        onEditingChange: { session.setSizeEditing($0) }
      )
      .id(session.planRevision)
      if let notice = session.allocationNotice {
        Text(notice).font(OmarchyTheme.body).foregroundStyle(OmarchyTheme.caution)
      }
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
      .disabled(!acknowledged || session.isBusy || session.isEditingSize)
      .keyboardShortcut(.defaultAction)

    case .awaitingInstall:
      Button("Edit disk size") { session.editPlan() }
        .omarchySecondaryButton()
        .disabled(!session.canEditPlan)
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
      Button("Close") { NSApplication.shared.terminate(nil) }
        .omarchySecondaryButton()

    case .failed(let failure):
      if session.canInspect {
        Button("Check again") { Task { await session.inspect() } }
          .omarchySecondaryButton()
      }
      if failure.retryRecoveryAvailable {
        Button(PlainLanguage.retry) { showsRecoveryRetryConfirmation = true }
          .omarchyPrimaryButton()
          .disabled(!session.canRetryRecoveryAuthorization)
          .keyboardShortcut(.defaultAction)
      } else if let url = failure.actionURL, let title = failure.actionTitle {
        Button(title) {
          if !session.isSimulation { NSWorkspace.shared.open(url) }
        }
        .disabled(session.isSimulation)
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
          DisclosureGroup("Technical details") {
            TechnicalDetailText(text: technical)
            Button("Copy error details") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(technical, forType: .string)
            }
          }.padding(.top, 4)
        }
        if session.hasExecutionStarted {
          Text(
            "The previous installation result must be checked before you can start again. Keep your Mac connected to power."
          )
          .font(OmarchyTheme.body)
          DisclosureGroup("Last verified steps") {
            if session.journal.feed.isEmpty {
              Text(
                "No completed disk step was confirmed. Disk changes may still have started."
              )
            }
            Button("Copy installation record") {
              let record = ([headline, detail, technical ?? ""] + session.journal.feed.map(\.text))
                .joined(separator: "\n")
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(record, forType: .string)
            }
            ForEach(session.journal.feed) { line in
              Text(line.text).font(OmarchyTheme.caption).textSelection(.enabled)
            }
          }
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
      Text(
        "To remove it and return its space to macOS, choose Installation → Remove Omarchy from the menu bar."
      )
      .font(OmarchyTheme.body)
      .foregroundStyle(OmarchyTheme.secondaryText)
      .fixedSize(horizontal: false, vertical: true)
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
    .disabled(session.isBusy || session.isEditingSize)
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
      if let message = session.shutdownMessage {
        Text(message).font(OmarchyTheme.body).foregroundStyle(OmarchyTheme.caution)
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

  private var approvedSize: String? {
    guard case .awaitingInstall(let plan, _, _) = session.phase else { return nil }
    return PlainLanguage.bytes(plan.omarchyBytes)
  }

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
  var onEditingChange: (Bool) -> Void = { _ in }

  @State private var exploredOmarchyGB: Double?
  @State private var sizeInput = DiskSizeInput()
  @FocusState private var sizeFocused: Bool

  var body: some View {
    Panel {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          Text(plan.fixedMacOSBytes == nil ? "macOS" : "macOS + free space")
            .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(OmarchyTheme.accent)
          Spacer(minLength: 8)
          Text("Omarchy")
            .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(OmarchyTheme.accent)
        }
        DiskBar(
          macOSBytes: plan.macOSBytes(for: displayedOmarchyBytes),
          omarchyBytes: displayedOmarchyBytes,
          unallocatedBytes: plan.unallocatedBytes(for: displayedOmarchyBytes),
          onAdjustOmarchyFraction: editable ? { adjust($0) } : nil,
          onCommitOmarchyFraction: editable ? { commit($0) } : nil,
          isFrozen: isBusy || sizeInput.isEditing
        )
        .transaction { $0.animation = nil }
        if editable {
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
              Text("Space for Omarchy").font(OmarchyTheme.body)
              TextField(
                "Size",
                text: Binding(
                  get: {
                    sizeInput.isEditing ? sizeInput.text : sizeInput.display(plan.omarchyBytes)
                  },
                  set: { value in
                    beginSizeEdit()
                    sizeInput.text = value
                  }
                )
              )
              .textFieldStyle(.roundedBorder)
              .font(OmarchyTheme.body.monospacedDigit())
              .frame(width: 62, height: 28)
              .focused($sizeFocused)
              .onTapGesture {
                beginSizeEdit()
                sizeFocused = true
              }
              .accessibilityLabel("Omarchy size in gigabytes")
              .onSubmit(applySize)
              .onExitCommand(perform: cancelSize)
              Text("GB").font(OmarchyTheme.caption)
              if sizeInput.isEditing {
                Button(action: applySize) {
                  Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(SizeEditButtonStyle(tint: OmarchyTheme.success))
                .accessibilityLabel("Apply size")
                .help("Apply size (Return)")
                .disabled(sizeInput.requestedBytes == nil)
                Button(action: cancelSize) {
                  Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(SizeEditButtonStyle(tint: OmarchyTheme.danger))
                .accessibilityLabel("Cancel size edit")
                .help("Cancel size edit (Escape)")
              }
              Spacer(minLength: 0)
            }
            if let message = sizeInput.validationMessage {
              Text(message).font(OmarchyTheme.caption).foregroundStyle(OmarchyTheme.danger)
            }
          }
          .disabled(isBusy)

        }
        if plan.fixedMacOSBytes != nil {
          Text(
            "\(PlainLanguage.bytes(plan.unallocatedBytes(for: displayedOmarchyBytes))) remains unallocated. macOS keeps its current size."
          )
          .font(OmarchyTheme.body)
        }
        Text(
          "Omarchy will use the space shown above. Finish setup in Recovery after restarting."
        )
        .font(OmarchyTheme.body)
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

  private func beginSizeEdit() {
    guard !isBusy && editable else { return }
    sizeInput.begin(
      bytes: plan.omarchyBytes, minimum: plan.minimumBytes, maximum: plan.maximumBytes)
    onEditingChange(true)
  }

  private func applySize() {
    guard !isBusy, let chosen = sizeInput.apply() else { return }
    sizeFocused = false
    onEditingChange(false)
    if chosen != plan.omarchyBytes { onSizeChosen(chosen) }
  }

  private func cancelSize() {
    sizeInput.cancel()
    sizeFocused = false
    onEditingChange(false)
  }

  private func adjust(_ fraction: Double) {
    let requested = Double(plan.diskTotalBytes) * min(1, max(0, fraction))
    let chosen = min(Double(plan.maximumBytes), max(Double(plan.minimumBytes), requested))
    exploredOmarchyGB = chosen / 1_000_000_000
  }

  private func commit(_ fraction: Double) {
    adjust(fraction)
    let rounded = (Double(displayedOmarchyBytes) / 1_000_000_000).rounded() * 1_000_000_000
    let chosen = min(plan.maximumBytes, max(plan.minimumBytes, UInt64(rounded)))
    if chosen != plan.omarchyBytes {
      onSizeChosen(chosen)
    } else {
      exploredOmarchyGB = nil
    }
  }
}

// MARK: - The install bar

/// Stage count and verified activity describe progress without inventing a
/// percentage for operations whose duration is unknown.
private struct InstallPanel: View {
  let progress: InstallProgressDisplay
  @State private var estimate = InstallationProgressEstimate(
    expectedSeconds: InstallationTimingHistory.expectedSeconds)

  private var stageLabel: String {
    let index = progress.stageIndex
    if progress.stageLabels.indices.contains(index) {
      return progress.phaseTitle
    }
    return progress.phaseTitle
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
          Text(
            "Step \(min(progress.stageIndex + 1, progress.stageLabels.count)) of \(progress.stageLabels.count)"
          )
          .font(OmarchyTheme.body.monospacedDigit())
        }
        TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
          let elapsed = max(0, context.date.timeIntervalSince(progress.startedAt))
          VStack(alignment: .leading, spacing: 6) {
            ProgressTrack(fraction: estimate.fraction, height: 18)
            HStack {
              Text("Estimated progress · \(Int(estimate.fraction * 100))%")
              Spacer()
              if let minutes = estimate.remainingMinutes(elapsed: elapsed) {
                Text("About \(minutes) min remaining")
              } else {
                Text("Taking longer than estimated")
              }
            }
            .font(OmarchyTheme.caption.monospacedDigit())
            .foregroundStyle(OmarchyTheme.secondaryText)
          }
          .onChange(of: context.date, initial: true) { _, date in
            estimate.update(
              elapsed: date.timeIntervalSince(progress.startedAt),
              completedStages: progress.stageFractions.filter { $0 >= 1 }.count)
          }
        }
        DisclosureGroup("View activity") {
          ForEach(progress.feed) { line in
            Text(line.text).font(OmarchyTheme.caption).textSelection(.enabled)
          }
        }
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

/// Quiet, keyboard-sized actions that share the editor's terminal palette.
private struct SizeEditButtonStyle: ButtonStyle {
  let tint: Color
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    SizeEditButtonBody(configuration: configuration, tint: tint, isEnabled: isEnabled)
  }

  private struct SizeEditButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    let isEnabled: Bool
    @State private var isHovered = false

    var body: some View {
      configuration.label
        .foregroundStyle(isEnabled ? tint : OmarchyTheme.secondaryText.opacity(0.4))
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(
              tint.opacity(
                isEnabled && configuration.isPressed ? 0.20 : isEnabled && isHovered ? 0.10 : 0))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 4)
            .strokeBorder(
              isEnabled && isHovered ? tint.opacity(0.35) : OmarchyTheme.separator.opacity(0.5),
              lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
  }
}

private struct InstallerContentHeight: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}
