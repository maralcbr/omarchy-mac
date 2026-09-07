#if os(macOS)
  import XCTest
  @testable import OmarchyInstallerUXCore

  final class InstallationProgressEstimateTests: XCTestCase {
    func testEstimateAdvancesWithoutClaimingCompletion() {
      var estimate = InstallationProgressEstimate()
      estimate.update(elapsed: 60, completedStages: 0)
      let first = estimate.fraction
      estimate.update(elapsed: 120, completedStages: 0)
      XCTAssertGreaterThan(estimate.fraction, first)
      estimate.update(elapsed: 100_000, completedStages: 3)
      XCTAssertLessThan(estimate.fraction, 1)
      XCTAssertNil(estimate.remainingMinutes(elapsed: 800))
    }

    func testClockOrCheckpointRegressionCannotMoveTheBarBack() {
      var estimate = InstallationProgressEstimate()
      estimate.update(elapsed: 400, completedStages: 2)
      XCTAssertEqual(estimate.remainingMinutes(elapsed: 10), 1)
      let previous = estimate.fraction
      estimate.update(elapsed: 10, completedStages: 0)
      XCTAssertEqual(estimate.fraction, previous)
    }
  }
#endif
