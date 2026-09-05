#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore

  /// Remembers which release channel this Mac reads.
  ///
  /// The preference only chooses between the two URLs already baked into the
  /// signed app bundle, so it can never introduce a source the app was not
  /// built to trust.
  public struct ReleaseChannelPreference: @unchecked Sendable {
    public static let defaultsKey = "ReleaseChannel"

    // UserDefaults is thread-safe but not marked Sendable.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
      self.defaults = defaults
    }

    /// The stored choice, or `nil` when none was made or the stored value is
    /// not a channel this build knows.
    public var stored: ReleaseChannel? {
      guard let value = defaults.string(forKey: Self.defaultsKey) else {
        return nil
      }
      return ReleaseChannel(rawValue: value)
    }

    public func select(_ channel: ReleaseChannel?) {
      guard let channel else {
        defaults.removeObject(forKey: Self.defaultsKey)
        return
      }
      defaults.set(channel.rawValue, forKey: Self.defaultsKey)
    }

    public func resolve(descriptorDefault: ReleaseChannel) -> ReleaseChannel {
      stored ?? descriptorDefault
    }
  }
#endif
