import AppKit
import OmarchyAppleInstallerTrustCore
import OmarchyInstallerUXCore
import SwiftUI

struct OmarchyRemovalSheet: View {
  let isSimulation: Bool
  let onBusyChanged: (Bool) -> Void
  let onClose: () -> Void
  let onRequiresReview: () -> Void

  @State private var ticket: OmarchyRemovalTicket?
  @State private var phrase = ""
  @State private var username = NSUserName()
  @State private var password = ""
  @State private var busy = false
  @State private var submitted = false
  @State private var completed = false
  @State private var message = "Checking for an existing Omarchy installation…"
  @State private var client: AuthenticatedEngineXPCSubmitter?
  #if DEBUG
    @State private var scenario = RemovalPreviewScenario.success
  #endif

  private var canRemove: Bool {
    ticket != nil && !busy && !submitted && phrase == OmarchyRemovalTicket.confirmation
      && (isSimulation || (!username.isEmpty && !password.isEmpty))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(completed ? "Omarchy removed" : "Remove Omarchy")
        .font(.system(size: 23, weight: .semibold))
        .foregroundStyle(OmarchyTheme.accent)
      #if DEBUG
        if isSimulation {
          Picker("Removal test", selection: $scenario) {
            ForEach(RemovalPreviewScenario.allCases, id: \.self) { item in
              Text(item.rawValue).tag(item)
            }
          }
          .disabled(busy)
          .onChange(of: scenario) { _, _ in Task { await prepare() } }
          Text("SIMULATION · No disks will be changed")
            .font(OmarchyTheme.caption)
            .foregroundStyle(OmarchyTheme.secondaryText)
        }
      #endif
      Text(message)
        .font(OmarchyTheme.body)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("removal-message")
      if let ticket, !submitted {
        VStack(spacing: 10) {
          summaryRow("Space returned to macOS", value: PlainLanguage.bytes(ticket.reclaimBytes))
          summaryRow("macOS after removal", value: PlainLanguage.bytes(ticket.macOSBytesAfter))
        }
        .padding(14)
        .background(OmarchyTheme.card, in: RoundedRectangle(cornerRadius: 8))
        Text("Your macOS files and Apple Recovery will be kept. This cannot be undone.")
          .font(OmarchyTheme.body)
          .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 7) {
          Text("Type the following to confirm:")
            .foregroundStyle(OmarchyTheme.secondaryText)
          Text(OmarchyRemovalTicket.confirmation)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .textSelection(.enabled)
          TextField("Confirmation phrase", text: $phrase)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .accessibilityIdentifier("removal-confirmation")
        }
        .font(OmarchyTheme.body)
        if !isSimulation {
          VStack(alignment: .leading, spacing: 7) {
            Text("macOS administrator account").foregroundStyle(OmarchyTheme.secondaryText)
            TextField("Account name", text: $username)
              .textFieldStyle(.roundedBorder)
              .textContentType(.username)
              .autocorrectionDisabled()
            SecureField("macOS password", text: $password)
              .textFieldStyle(.roundedBorder)
              .textContentType(.password)
              .privacySensitive()
          }
          .font(OmarchyTheme.body)
        }
      }
      if busy {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text(submitted ? "Keep your Mac on until removal finishes." : "Reading the disk layout…")
            .font(OmarchyTheme.caption)
        }
        .foregroundStyle(OmarchyTheme.secondaryText)
      }
      HStack(spacing: 12) {
        Spacer()
        Button(submitted || ticket == nil ? "Close" : "Cancel") {
          password = ""
          onClose()
        }
        .omarchySecondaryButton()
        .keyboardShortcut(.cancelAction)
        .focusEffectDisabled()
        .disabled(busy)
        if ticket != nil && !submitted {
          Button("Remove Omarchy", role: .destructive) { Task { await remove() } }
            .buttonStyle(RemovalButtonStyle())
            .disabled(!canRemove)
            .accessibilityIdentifier("remove-omarchy")
        }
      }
      .padding(.top, 4)
    }
    .padding(26)
    .frame(width: 520)
    .foregroundStyle(OmarchyTheme.text)
    .background(OmarchyTheme.window)
    .interactiveDismissDisabled(busy)
    .task { await prepare() }
    .onDisappear { password = "" }
    .onChange(of: busy) { _, value in onBusyChanged(value) }
  }

  private func summaryRow(_ label: String, value: String) -> some View {
    HStack {
      Text(label).foregroundStyle(OmarchyTheme.secondaryText)
      Spacer()
      Text(value).fontWeight(.medium)
    }.font(OmarchyTheme.body)
  }

  @MainActor private func prepare() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    ticket = nil
    phrase = ""
    password = ""
    submitted = false
    completed = false
    message = "Checking for an existing Omarchy installation…"
    #if DEBUG
      if isSimulation {
        try? await Task.sleep(for: .milliseconds(350))
        if scenario == .none || scenario == .ambiguous || scenario == .helperUnavailable {
          message = scenario.message
        } else {
          ticket = OmarchyRemovalTicket(
            id: UUID(), reclaimBytes: 275_000_000_000, macOSBytesAfter: 995_000_000_000)
          message = "Omarchy and all files stored in it will be permanently deleted."
        }
        return
      }
    #endif
    do {
      let configuration = try InstallerReleaseConfigurationLocator().loadFromMainBundle()
      let submitter = try AuthenticatedEngineXPCSubmitter(
        machServiceName: configuration.helperMachServiceName,
        helperCodeSigningRequirement: configuration.helperCodeSigningRequirement)
      client = submitter
      let reply = try await submitter.removal()
      ticket = reply.ticket
      message = reply.message
    } catch {
      message =
        "The removal helper is unavailable. Install the current app and helper, then try again. No disk changes were made."
    }
  }

  @MainActor private func remove() async {
    guard canRemove, let ticket else { return }
    let authorization: MachineOwnerAuthorization?
    do {
      authorization =
        isSimulation
        ? nil : try MachineOwnerAuthorization(username: username, password: Data(password.utf8))
    } catch {
      message = "Enter a valid macOS administrator account and password."
      return
    }
    password = ""
    busy = true
    submitted = true
    message = "Removing Omarchy, then returning its space to macOS…"
    defer { busy = false }
    #if DEBUG
      if isSimulation {
        try? await Task.sleep(for: .seconds(2))
        if scenario == .disconnected {
          connectionLost()
          return
        }
        completed = scenario == .success
        if [.interrupted, .reclaimFailed, .disconnected].contains(scenario) { onRequiresReview() }
        message = scenario.message
        return
      }
    #endif
    do {
      guard let client else { throw EngineXPCSubmissionError.connectionFailed }
      let reply = try await client.removal(
        ticket: ticket, confirmation: phrase, authorization: authorization)
      completed = reply.completed
      if reply.requiresReview { onRequiresReview() }
      message = reply.message
    } catch {
      connectionLost()
    }
  }

  private func connectionLost() {
    onRequiresReview()
    message =
      "The helper connection was lost. Removal may still be running. Do not restart removal or turn off your Mac. Check the removal journal before continuing."
  }
}

private struct RemovalButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .medium))
      .padding(.horizontal, 16).padding(.vertical, 11)
      .foregroundStyle(enabled ? OmarchyTheme.window : OmarchyTheme.secondaryText)
      .background(
        enabled
          ? OmarchyTheme.danger.opacity(configuration.isPressed ? 0.8 : 1) : OmarchyTheme.card,
        in: RoundedRectangle(cornerRadius: 8))
  }
}

#if DEBUG
  private enum RemovalPreviewScenario: String, CaseIterable {
    case success = "Complete removal"
    case none = "No installation"
    case ambiguous = "Unfamiliar or partial layout"
    case helperUnavailable = "Helper unavailable"
    case credentials = "Incorrect password"
    case changed = "Disk changed since confirmation"
    case interrupted = "Deletion interrupted"
    case reclaimFailed = "macOS resize failed"
    case disconnected = "Connection lost"

    var message: String {
      switch self {
      case .success: "Omarchy and its data have been removed. The freed space is now part of macOS."
      case .none: "No existing Omarchy installation was found. Nothing was changed."
      case .ambiguous:
        "The installation or disk layout could not be identified safely. Partial installations need a separate review. Nothing was changed."
      case .helperUnavailable:
        "The removal helper is unavailable. Install the current app and helper, then try again. No disk changes were made."
      case .credentials:
        "The macOS account or password was not accepted. No disk changes were made."
      case .changed:
        "The disk layout changed since you reviewed it. No disk changes were made. Close this window and review removal again."
      case .interrupted:
        "Removal stopped and some Omarchy data may already be deleted. Do not repeat deletion; the removal journal was kept for recovery."
      case .reclaimFailed:
        "Omarchy was removed, but returning its space to macOS could not be confirmed. The space may still be unallocated. Do not repeat deletion; the removal journal was kept for recovery."
      case .disconnected:
        "The helper connection was lost. Removal may still be running. Do not restart removal or turn off your Mac. Check the removal journal before continuing."
      }
    }
  }
#endif
