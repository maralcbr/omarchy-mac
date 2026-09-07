#if os(macOS)
  import Foundation

  /// Presentation only: an estimate never authorizes a transition or reports completion.
  // Five minutes is an initial prediction for the fast engine, not a measured guarantee.
  public struct InstallationProgressEstimate: Sendable {
    public private(set) var fraction: Double = 0
    public let expectedSeconds: TimeInterval

    public init(expectedSeconds: TimeInterval = 5 * 60) {
      self.expectedSeconds = max(1, expectedSeconds)
    }

    public mutating func update(elapsed: TimeInterval, completedStages: Int) {
      let elapsed = max(0, elapsed)
      let timed =
        elapsed <= expectedSeconds
        ? 0.9 * elapsed / expectedSeconds
        : 0.9 + 0.05 * (1 - exp(-(elapsed - expectedSeconds) / expectedSeconds))
      let milestones = [0.0, 0.15, 0.90, 0.95]
      fraction = min(0.95, max(fraction, timed, milestones[min(3, max(0, completedStages))]))
    }

    public func remainingMinutes(elapsed: TimeInterval) -> Int? {
      guard elapsed < expectedSeconds else { return nil }
      let remaining = min(expectedSeconds - max(0, elapsed), expectedSeconds * (1 - fraction))
      return max(1, Int(ceil(remaining / 60)))
    }
  }
#endif
