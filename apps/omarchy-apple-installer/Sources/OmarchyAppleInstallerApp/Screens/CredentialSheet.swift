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
  let approvedSize: String?
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
    VStack(alignment: .leading, spacing: 16) {
      Text(isRetry ? PlainLanguage.authorizeRetryTitle : PlainLanguage.authorizeTitle)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(OmarchyTheme.accent)

      Text(
        isSimulation
          ? "This simulation uses a test account. No real password is needed."
          : "Use a macOS account authorized to install on this Mac. Your password authorizes the disk changes you reviewed and the Recovery setup."
      )
      .font(OmarchyTheme.body)
      .fixedSize(horizontal: false, vertical: true)

      HStack {
        Text(isRetry ? "Approved operation" : "Space for Omarchy")
          .foregroundStyle(OmarchyTheme.secondaryText)
        Spacer()
        Text(isRetry ? "Recovery authorization only" : approvedSize ?? "Reviewed allocation")
          .fontWeight(.medium)
      }
      .font(OmarchyTheme.body)
      .padding(12)
      .background(OmarchyTheme.card, in: RoundedRectangle(cornerRadius: 4))

      field(label: PlainLanguage.authorizeUsernameLabel, reason: input.usernameReason) {
        TextField("", text: isSimulation ? .constant("simulation") : $input.username)
          .textFieldStyle(.roundedBorder)
          .textContentType(.username)
          .accessibilityLabel(PlainLanguage.authorizeUsernameLabel)
          .autocorrectionDisabled()
          .focused($focus, equals: .username)
          .onSubmit { focus = .password }
          .disabled(isSimulation)
      }
      field(label: PlainLanguage.authorizePasswordLabel, reason: input.passwordReason) {
        SecureField("", text: isSimulation ? .constant("simulation-only") : $input.password)
          .textFieldStyle(.roundedBorder)
          .textContentType(.password)
          .accessibilityLabel(PlainLanguage.authorizePasswordLabel)
          .privacySensitive()
          .focused($focus, equals: .password)
          .onSubmit(submit)
          .disabled(isSimulation)
      }

      if context.isVerifying || context.error == .credentialsRejected {
        HStack(alignment: .top, spacing: 8) {
          if context.isVerifying {
            ProgressView().controlSize(.small)
            Text(
              showsLongWait ? PlainLanguage.authorizeStillWorking : PlainLanguage.authorizeChecking)
          } else if context.error == .credentialsRejected {
            Image(systemName: "exclamationmark.triangle")
            Text(PlainLanguage.authorizeRejected).foregroundStyle(OmarchyTheme.danger)
          }
        }
        .font(OmarchyTheme.caption)
        .foregroundStyle(OmarchyTheme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
      }

      HStack(spacing: 12) {
        Spacer(minLength: 0)
        Button(PlainLanguage.authorizeCancel, action: cancel)
          .omarchySecondaryButton()
          .fixedSize()
          .keyboardShortcut(.cancelAction)
          .focusEffectDisabled()
        Button(isRetry ? "Authorize Recovery" : "Authorize & install", action: submit)
          .omarchyPrimaryButton()
          .fixedSize()
          .keyboardShortcut(.defaultAction)
          .disabled(!input.isValid)
      }
      .padding(.top, 8)
    }
    .padding(24)
    .frame(width: 456)
    .foregroundStyle(OmarchyTheme.text)
    .background(OmarchyTheme.window)
    .disabled(context.isVerifying)
    .onAppear {
      input.username = isSimulation ? "simulation" : NSUserName()
      if isSimulation { input.password = "simulation-only" }
      if !isSimulation { focus = input.username.isEmpty ? .username : .password }
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
        if !isSimulation { focus = .password }
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
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(OmarchyTheme.secondaryText)
      content()
        .controlSize(.large)
        .frame(height: 36)
      if let reason {
        Text(reason)
          .font(.system(size: 10))
          .foregroundStyle(OmarchyTheme.secondaryText)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)

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
