import AppKit
import OmarchyAppleInstallerTrustCore
import OmarchyInstallerUXCore
import SwiftUI

/// Screen C — the machine-owner authorization sheet.
///
/// Password lifecycle (unchanged from the previous view): the password exists
/// only as sheet-local state, is converted straight into a
/// `MachineOwnerAuthorization` on submit, and is cleared at the same three
/// points — on submit, on cancel, and unconditionally on disappear. Nothing
/// above the XPC boundary can retain the string: the session and environment
/// APIs accept only `MachineOwnerAuthorization`.
struct CredentialSheet: View {
  let context: CredentialSheetContext
  let isSimulation: Bool
  let onCancel: () -> Void
  let onSubmit: (MachineOwnerAuthorization) -> Void

  @State private var input = CredentialInput(username: "")
  @FocusState private var focus: Field?
  @State private var showsLongWait = false

  private enum Field: Hashable {
    case username
    case password
  }

  var body: some View {
    VStack(spacing: 0) {
      Text(isRetry ? PlainLanguage.authorizeRetryTitle : PlainLanguage.authorizeTitle)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(OmarchyTheme.accent)
        .multilineTextAlignment(.center)
        .padding(.bottom, 14)

      if context.error == .credentialsRejected {
        Text(PlainLanguage.authorizeRejected)
          .font(OmarchyTheme.caption)
          .foregroundStyle(OmarchyTheme.danger)
          .padding(.bottom, 10)
      }

      Text(
        isSimulation
          ? "Simulation uses a dummy account. Do not enter a real password."
          : "Use the macOS account that owns this Mac. Its login password authorizes the reviewed disk changes and Recovery setup; it is not an Omarchy account password."
      )
      .font(OmarchyTheme.body)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 14)

      if !isSimulation {
        field(
          label: PlainLanguage.authorizeUsernameLabel,
          reason: input.usernameReason
        ) {
          TextField("", text: $input.username)
            .textFieldStyle(.roundedBorder)
            .textContentType(.username)
            .accessibilityLabel(PlainLanguage.authorizeUsernameLabel)
            .autocorrectionDisabled()
            .focused($focus, equals: .username)
            .onSubmit { focus = .password }
        }

        field(
          label: PlainLanguage.authorizePasswordLabel,
          reason: input.passwordReason
        ) {
          SecureField("", text: $input.password)
            .textFieldStyle(.roundedBorder)
            .textContentType(.password)
            .accessibilityLabel(PlainLanguage.authorizePasswordLabel)
            .privacySensitive()
            .focused($focus, equals: .password)
            .onSubmit(submit)
        }

      }

      if context.isVerifying, showsLongWait {
        Text(PlainLanguage.authorizeStillWorking)
          .font(OmarchyTheme.caption)
          .foregroundStyle(OmarchyTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 10)
      }

      HStack(spacing: 8) {
        if context.isVerifying {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(PlainLanguage.authorizeChecking)
        }
        Spacer(minLength: 0)
        // fixedSize keeps both buttons at their natural width: the row is
        // narrow, and a squeezed button truncates its label.
        Button(PlainLanguage.authorizeCancel, action: cancel)
          .omarchySecondaryButton()
          .fixedSize()
          .keyboardShortcut(.cancelAction)
          .disabled(context.isVerifying)
        Button(
          isRetry ? PlainLanguage.authorizeRetryAction : PlainLanguage.planInstall,
          action: submit
        )
        .omarchyPrimaryButton()
        .fixedSize()
        .keyboardShortcut(.defaultAction)
        .disabled(!input.isValid || context.isVerifying)
      }
      .padding(.top, 14)
    }
    .padding(24)
    .frame(width: 380)
    .foregroundStyle(OmarchyTheme.text)
    .background(OmarchyTheme.window)
    .disabled(context.isVerifying)
    .animation(.easeInOut(duration: 0.2), value: context.isVerifying)
    .animation(.easeInOut(duration: 0.2), value: context.error)
    .onAppear {
      input.username = isSimulation ? "simulation" : NSUserName()
      if isSimulation { input.password = "simulation-only" }
      focus = input.username.isEmpty ? .username : .password
    }
    // The spinner alone reads as stuck once the helper moves from checking
    // the password to preparing the package; after a few seconds say so.
    .task(id: context.isVerifying) {
      showsLongWait = false
      guard context.isVerifying else { return }
      try? await Task.sleep(for: .seconds(5))
      if !Task.isCancelled {
        showsLongWait = true
      }
    }
    .onChange(of: context.error) { _, error in
      if error == .credentialsRejected {
        if isSimulation { input.password = "simulation-only" }
        focus = .password
      }
    }
    .onDisappear {
      input.clearPassword()
    }
  }

  private var isRetry: Bool {
    context.kind == .retryRecoveryAuthorization
  }

  private func field<Content: View>(
    label: String,
    reason: String?,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(OmarchyTheme.secondaryText)
      content()
      if let reason {
        Text(reason)
          .font(.system(size: 10))
          .foregroundStyle(OmarchyTheme.secondaryText)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, 10)
  }

  private func submit() {
    guard let authorization = input.validated() else {
      return
    }
    input.clearPassword()
    onSubmit(authorization)
  }

  private func cancel() {
    input.clearPassword()
    onCancel()
  }
}
