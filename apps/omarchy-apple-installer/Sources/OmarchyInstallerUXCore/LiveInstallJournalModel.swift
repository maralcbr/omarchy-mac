#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore

  /// Consumes the advisory journal stream the helper forwards while the engine
  /// runs, and turns it into display state.
  ///
  /// Two rules keep this display-only:
  /// 1. Every mutation is re-validated with the public
  ///    `validateEngineTranscript(_:)`, the same decoder the authoritative
  ///    post-run path uses; nothing is displayed that the trust core rejected.
  /// 2. A validation failure sets `degraded` and freezes the last good state.
  ///    It never throws, never fails the install, and never cancels anything —
  ///    the authoritative outcome still arrives on the XPC reply path.
  public struct LiveInstallJournalModel: Sendable {
    public static let stagePhases = [
      "apfs_preparation", "stub_and_esp", "awaiting_recovery",
    ]

    private static let phaseOrder = [
      "preflight": 0,
      "apfs_preparation": 1,
      "stub_and_esp": 2,
      "awaiting_recovery": 3,
      "boot_policy": 4,
      "media_handoff": 5,
      "omarchy_install": 6,
    ]

    public private(set) var raw = Data()
    public private(set) var degraded = false
    public private(set) var checkpoints = [ValidatedEngineCheckpoint]()
    public private(set) var completion: EngineCompletionOutcome?
    public private(set) var lastEventName: String?
    public private(set) var feed = [JournalFeedLine]()

    public init() {}

    public var currentPhase: String? {
      if let highest = checkpoints.max(by: { left, right in
        (Self.phaseOrder[left.phase] ?? -1) < (Self.phaseOrder[right.phase] ?? -1)
      }) {
        return highest.phase
      }
      return nil
    }

    public mutating func consume(_ chunk: Data) {
      guard !chunk.isEmpty else {
        return
      }
      if !raw.isEmpty, Self.beginsAtFirstSequence(chunk) {
        raw = chunk
      } else {
        raw.append(chunk)
      }
      revalidate()
    }

    public mutating func reset() {
      raw = Data()
      degraded = false
      checkpoints = []
      completion = nil
      lastEventName = nil
      feed = []
    }

    /// The number of the stage currently being worked on (0-based), derived
    /// from the highest checkpoint reached plus the last started event.
    public var stageIndex: Int {
      let completedStages = Self.stagePhases.filter { phase in
        checkpoints.contains { $0.phase == phase }
      }.count
      if completion != nil {
        return max(0, Self.stagePhases.count - 1)
      }
      return min(completedStages, Self.stagePhases.count - 1)
    }

    public var stageFractions: [Double] {
      Self.stagePhases.map { phase in
        checkpoints.contains { $0.phase == phase } ? 1 : 0
      }
    }

    /// The most recent thing the engine actually reported: the phase of the
    /// last started event when it is at or beyond the last checkpoint,
    /// otherwise the last completed checkpoint's phase.
    public var phaseTitle: String {
      let eventPhase = Self.phase(forEvent: lastEventName)
      let checkpointPhase = currentPhase
      let eventOrder = eventPhase.flatMap { Self.phaseOrder[$0] } ?? -1
      let checkpointOrder = checkpointPhase.flatMap { Self.phaseOrder[$0] } ?? -1

      if completion != nil {
        return PlainLanguage.installPhaseTitle(
          forPhase: checkpointPhase ?? eventPhase
        )
      }
      if let eventPhase, eventOrder >= checkpointOrder {
        return PlainLanguage.installPhaseTitle(forPhase: eventPhase)
      }
      if let checkpointPhase {
        return PlainLanguage.installPhaseTitle(forPhase: checkpointPhase)
      }
      return PlainLanguage.installVerifyingOwner
    }

    public func display(startedAt: Date) -> InstallProgressDisplay {
      InstallProgressDisplay(
        phaseTitle: phaseTitle,
        stageIndex: stageIndex,
        stageFractions: stageFractions,
        stageLabels: PlainLanguage.installStageLabels,
        feed: feed,
        degraded: degraded,
        startedAt: startedAt
      )
    }

    private mutating func revalidate() {
      guard raw.last == 0x0A else {
        degraded = true
        return
      }
      guard
        let validated = try? AppleInstallerTrustCore()
          .validateEngineTranscript(raw)
      else {
        degraded = true
        return
      }
      degraded = false
      checkpoints = validated.checkpoints
      completion = validated.completion
      rebuildFeed()
    }

    private mutating func rebuildFeed() {
      var lines = [JournalFeedLine]()
      var lastEvent: String?
      for (index, line) in Self.lines(in: raw).enumerated() {
        guard let envelope = Self.envelope(line) else {
          continue
        }
        switch envelope.type {
        case "event":
          guard let name = envelope.name else { continue }
          lastEvent = name
          lines.append(
            JournalFeedLine(
              id: index,
              kind: .event,
              text: PlainLanguage.eventSummary(name)
            )
          )
        case "checkpoint":
          guard let identifier = envelope.identifier else { continue }
          let evidence =
            envelope.evidenceDigest.map {
              " · verification \(PlainLanguage.shortDigest($0))"
            } ?? ""
          lines.append(
            JournalFeedLine(
              id: index,
              kind: .checkpoint,
              text: PlainLanguage.checkpointSummary(identifier) + " ✓" + evidence
            )
          )
        case "completion":
          guard let outcome = envelope.outcome else { continue }
          lines.append(
            JournalFeedLine(
              id: index,
              kind: .completion,
              text: "Result: "
                + outcome.replacingOccurrences(
                  of: "_",
                  with: " "
                )
            )
          )
        default:
          continue
        }
      }
      feed = lines
      lastEventName = lastEvent
    }

    private static func phase(forEvent event: String?) -> String? {
      switch event {
      case "apfs_preparation_started": "apfs_preparation"
      case "stub_and_esp_started": "stub_and_esp"
      case "recovery_handoff_started": "awaiting_recovery"
      default: nil
      }
    }

    private static func beginsAtFirstSequence(_ chunk: Data) -> Bool {
      guard let first = lines(in: chunk).first,
        let envelope = envelope(first)
      else {
        return false
      }
      return envelope.sequence == 1
    }

    /// Newline-delimited records without their terminators. Empty lines are
    /// skipped; a trailing record with no newline is still returned.
    public static func lines(in data: Data) -> [Data] {
      var result = [Data]()
      var start = data.startIndex
      while let newline = data[start...].firstIndex(of: 0x0A) {
        if newline > start {
          result.append(Data(data[start..<newline]))
        }
        start = data.index(after: newline)
      }
      if start < data.endIndex {
        result.append(Data(data[start...]))
      }
      return result
    }

    private static func envelope(_ line: Data) -> JournalEnvelope? {
      guard
        let object = try? JSONSerialization.jsonObject(with: line)
          as? [String: Any]
      else {
        return nil
      }
      let payload = object["payload"] as? [String: Any]
      return JournalEnvelope(
        sequence: object["sequence"] as? Int,
        type: object["type"] as? String ?? "",
        name: payload?["name"] as? String,
        identifier: payload?["identifier"] as? String,
        evidenceDigest: payload?["evidence_digest"] as? String,
        outcome: payload?["outcome"] as? String
      )
    }

    private struct JournalEnvelope {
      let sequence: Int?
      let type: String
      let name: String?
      let identifier: String?
      let evidenceDigest: String?
      let outcome: String?
    }
  }
#endif
