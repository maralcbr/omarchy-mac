#if os(macOS)
  import Foundation
  import OSLog

  enum InstallerPerformance {
    private static let logger = Logger(subsystem: "com.omarchy.installer", category: "performance")

    static func measure<T>(_ phase: String, _ action: () throws -> T) rethrows -> T {
      let start = ProcessInfo.processInfo.systemUptime
      var completed = false
      defer {
        let seconds = ProcessInfo.processInfo.systemUptime - start
        logger.notice("phase=\(phase, privacy: .public) seconds=\(seconds) completed=\(completed)")
      }
      let result = try action()
      completed = true
      return result
    }
  }
#endif
