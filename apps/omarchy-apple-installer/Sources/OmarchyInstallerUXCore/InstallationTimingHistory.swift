#if os(macOS)
  import Foundation

  /// Calibrated only by successful live installs; simulator runs never write history.
  public enum InstallationTimingHistory {
    private static let key = "installer.fast-v1.completedSeconds"

    public static var expectedSeconds: TimeInterval {
      let value = UserDefaults.standard.double(forKey: key)
      return value.isFinite && value >= 30 && value <= 3_600 ? value : 300
    }

    public static func recordCompleted(seconds: TimeInterval) {
      guard seconds.isFinite, seconds >= 30, seconds <= 3_600 else { return }
      UserDefaults.standard.set(seconds, forKey: key)
    }
  }
#endif
