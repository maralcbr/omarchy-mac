#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore
  import XCTest

  @testable import OmarchyInstallerUXCore

  final class LiveInstallJournalModelTests: XCTestCase {
    func testFixtureReplayProducesPhaseProgression() throws {
      let lines = try JournalFixture.lines()
      var model = LiveInstallJournalModel()
      var titles = [String]()

      for line in lines {
        model.consume(line)
        titles.append(model.phaseTitle)
      }

      XCTAssertFalse(model.degraded)
      XCTAssertEqual(
        model.checkpoints.map(\.identifier),
        [
          "apfs-target-prepared", "stub-and-esp-installed",
          "recovery-handoff-prepared",
        ]
      )
      XCTAssertEqual(model.completion, .awaitingRecovery)
      XCTAssertEqual(model.stageFractions, [1, 1, 1])
      XCTAssertEqual(model.stageIndex, 2)
      XCTAssertTrue(titles.contains("Preparing disk space…"))
      XCTAssertTrue(titles.contains("Writing boot files…"))
      XCTAssertTrue(titles.contains("Preparing the Recovery step…"))
      XCTAssertEqual(model.feed.count, 7)
      XCTAssertEqual(model.feed.last?.kind, .completion)
    }

    func testPartialReplayTracksTheStageInFlight() throws {
      let lines = try JournalFixture.lines()
      var model = LiveInstallJournalModel()

      // Through the first checkpoint and the second started event.
      for line in lines.prefix(6) {
        model.consume(line)
      }

      XCTAssertFalse(model.degraded)
      XCTAssertEqual(model.stageFractions, [1, 0, 0])
      XCTAssertEqual(model.stageIndex, 1)
      XCTAssertEqual(model.phaseTitle, "Writing boot files…")
      XCTAssertNil(model.completion)
    }

    func testCorruptLineDegradesWithoutThrowing() throws {
      let lines = try JournalFixture.lines()
      var model = LiveInstallJournalModel()
      for line in lines.prefix(4) {
        model.consume(line)
      }
      let goodCheckpoints = model.checkpoints

      model.consume(Data("{\"not\":\"an envelope\"}\n".utf8))

      XCTAssertTrue(model.degraded)
      XCTAssertEqual(model.checkpoints, goodCheckpoints)
      XCTAssertNil(model.completion)
    }

    func testSequenceRestartReplacesTheBuffer() throws {
      let lines = try JournalFixture.lines()
      var model = LiveInstallJournalModel()
      for line in lines {
        model.consume(line)
      }
      XCTAssertEqual(model.checkpoints.count, 3)

      // A reattach replays from offset zero on a fresh connection.
      let replay = lines.prefix(5).reduce(into: Data()) { $0.append($1) }
      model.consume(replay)

      XCTAssertFalse(model.degraded)
      XCTAssertEqual(model.checkpoints.map(\.identifier), ["apfs-target-prepared"])
      XCTAssertNil(model.completion)
      XCTAssertEqual(model.raw, replay)
    }

    func testWholeFileChunkIsAcceptedInOneGo() throws {
      let whole = try JournalFixture.data()
      var model = LiveInstallJournalModel()

      model.consume(whole)

      XCTAssertFalse(model.degraded)
      XCTAssertEqual(model.completion, .awaitingRecovery)
      XCTAssertEqual(model.stageIndex, 2)
    }

    func testResetClearsEverything() throws {
      var model = LiveInstallJournalModel()
      model.consume(try JournalFixture.data())

      model.reset()

      XCTAssertTrue(model.raw.isEmpty)
      XCTAssertFalse(model.degraded)
      XCTAssertTrue(model.checkpoints.isEmpty)
      XCTAssertTrue(model.feed.isEmpty)
      XCTAssertNil(model.completion)
    }
  }

  /// The recorded 2026-08-29 M1 fresh install, decoded by the real trust core.
  enum JournalFixture {
    static func url() -> URL {
      var root = URL(fileURLWithPath: #filePath)
      for _ in 0..<5 {
        root = root.deletingLastPathComponent()
      }
      return
        root
        .appendingPathComponent("evidence/apple-silicon")
        .appendingPathComponent("2026-08-29-m1-fresh-install-v6")
        .appendingPathComponent("execution-journal.jsonl")
    }

    static func data() throws -> Data {
      try Data(contentsOf: url())
    }

    static func lines() throws -> [Data] {
      let data = try data()
      var result = [Data]()
      var start = data.startIndex
      while let newline = data[start...].firstIndex(of: 0x0A) {
        result.append(Data(data[start...newline]))
        start = data.index(after: newline)
      }
      return result
    }
  }
#endif
