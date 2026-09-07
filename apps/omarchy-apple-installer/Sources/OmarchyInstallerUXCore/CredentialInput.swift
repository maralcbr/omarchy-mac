#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore

  /// Sheet-local validation for the machine-owner fields.
  ///
  /// The UI never re-implements the credential rules as a source of truth:
  /// `validated()` attempts the real `MachineOwnerAuthorization` initializer,
  /// so the enabled/disabled state of the primary button and the value that
  /// reaches XPC always agree. The inline reasons exist only to explain a
  /// rejection the initializer already made.
  public struct CredentialInput: Equatable, Sendable {
    public var username: String
    public var password: String

    public init(username: String = "", password: String = "") {
      self.username = username
      self.password = password
    }

    public func validated() -> MachineOwnerAuthorization? {
      try? MachineOwnerAuthorization(
        username: username,
        password: Data(password.utf8)
      )
    }

    public var isValid: Bool { validated() != nil }

    /// A short muted reason for the user name field, or nil when the field is
    /// empty (nothing to complain about yet) or acceptable.
    public var usernameReason: String? {
      guard !username.isEmpty else {
        return nil
      }
      if username.utf8.count > 255 {
        return "Account names can contain up to 255 characters."
      }
      let allowed = username.utf8.allSatisfy { byte in
        (byte >= 48 && byte <= 57)
          || (byte >= 65 && byte <= 90)
          || (byte >= 97 && byte <= 122)
          || byte == 46
          || byte == 95
          || byte == 45
      }
      return allowed
        ? nil
        : "Use your short macOS account name (letters, numbers, dots, underscores, or hyphens)."
    }

    public var passwordReason: String? {
      guard !password.isEmpty else {
        return nil
      }
      let bytes = Data(password.utf8)
      if bytes.count > 1_024 {
        return "This password exceeds the supported length."
      }
      if bytes.contains(0) || bytes.contains(0x0A) || bytes.contains(0x0D) {
        return "Enter the password without line breaks or null characters."
      }
      return nil
    }

    /// Clears the password only. The user name survives a rejection, exactly
    /// as the previous view did.
    public mutating func clearPassword() {
      password = ""
    }
  }
#endif
