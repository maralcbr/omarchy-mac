import OmarchyInstallerUXCore
import SwiftUI

/// The app's own confirmation: roomier than the system dialog, with the
/// wording, the buttons, and the space between them under the app's control.
/// Every confirmation in the installer uses this so they all look alike.
struct ConfirmationSheet: View {
  let title: String
  let message: String
  let action: String
  let onConfirm: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title)
        .font(.system(size: 19, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 14)
      Text(message)
        .font(.system(size: 14))
        .foregroundStyle(OmarchyTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 34)
      HStack(spacing: 16) {
        Spacer(minLength: 0)
        Button(PlainLanguage.cancel, action: onCancel)
          .omarchySecondaryButton()
          .keyboardShortcut(.cancelAction)
        Button(action, action: onConfirm)
          .omarchyPrimaryButton()
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(32)
    .frame(width: 520)
    .foregroundStyle(OmarchyTheme.text)
    .background(OmarchyTheme.window)
  }
}
