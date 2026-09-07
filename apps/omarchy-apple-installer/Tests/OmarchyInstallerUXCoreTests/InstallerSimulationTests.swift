#if DEBUG && os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore
  import XCTest
  @testable import OmarchyInstallerUXCore

  @MainActor
  final class InstallerSimulationTests: XCTestCase {
    func testDiskAlignmentDoesNotClaimSelected180GBIsACapacityLimit() async throws {
      let environment = InstallerSimulationEnvironment(scenario: .allocationAligned, delay: .zero)
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      await session.replan(omarchyBytes: 180_000_000_000)
      guard case .planReview(let plan, let acknowledged) = session.phase else {
        return XCTFail("Expected disk review")
      }
      XCTAssertNotEqual(plan.omarchyBytes, 180_000_000_000)
      XCTAssertEqual(DiskSizeInput().display(plan.omarchyBytes), "180")
      XCTAssertNil(session.allocationNotice)
      XCTAssertFalse(acknowledged)
    }

    func testSyntheticJournalPassesRealDecoder() throws {
      let data = InstallerSimulationEnvironment.journalLines.reduce(into: Data()) { $0.append($1) }
      let transcript = try AppleInstallerTrustCore().validateEngineTranscript(data)
      XCTAssertEqual(transcript.checkpoints.count, 3)
      XCTAssertEqual(transcript.completion, .awaitingRecovery)
    }

    func testEveryScenarioReachesItsExpectedOutcome() async throws {
      for scenario in InstallerSimulationScenario.allCases {
        let environment = InstallerSimulationEnvironment(scenario: scenario, delay: .zero)
        XCTAssertTrue(environment.isSimulation)
        let session = InstallerSession(environment: environment)
        await session.inspect()
        switch scenario {
        case .unsupported, .engineUnavailable:
          guard case .unsupported = session.phase else { return XCTFail(scenario.title) }
          XCTAssertFalse(session.canStartInstallation)
          continue
        case .existingInstall:
          guard case .existingInstallRefused = session.phase else { return XCTFail(scenario.title) }
          continue
        default: break
        }
        await session.continueToPlan()
        switch scenario {
        case .downloadFailure, .invalidDownload, .outdatedInstaller, .emptyChannel, .planFailure:
          guard case .failed = session.phase else { return XCTFail(scenario.title) }
          XCTAssertFalse(session.hasExecutionStarted)
          XCTAssertTrue(session.canInspect)
          continue
        default: break
        }
        session.continueToPlanReview()
        if scenario == .allocationClamped {
          session.setAcknowledged(true)
          await session.replan(omarchyBytes: 650_000_000_000)
          guard case .planReview(let plan, let acknowledged) = session.phase else {
            return XCTFail(scenario.title)
          }
          XCTAssertEqual(plan.omarchyBytes, 137_438_953_472)
          XCTAssertEqual(plan.maximumBytes, plan.omarchyBytes)
          XCTAssertFalse(acknowledged)
          XCTAssertEqual(session.planRevision, 2)
          XCTAssertNotNil(session.allocationNotice)
        }
        session.setAcknowledged(true)
        session.approve()
        if scenario == .approvalChanged {
          guard case .failed = session.phase else { return XCTFail(scenario.title) }
          XCTAssertFalse(environment.hasApprovedPlan)
          continue
        }
        if scenario == .missingHelper {
          XCTAssertFalse(session.canStartInstallation)
          XCTAssertTrue(session.canEditPlan)
          continue
        }
        session.presentInstallCredentials()
        let dummy = try MachineOwnerAuthorization(
          username: "simulation", password: Data("simulation-only".utf8))
        await session.submit(dummy)
        if scenario == .credentialsRejected {
          XCTAssertEqual(session.credentialSheet.context?.error, .credentialsRejected)
          XCTAssertFalse(session.hasExecutionStarted)
          await session.submit(dummy)
        }
        if scenario == .recoveryRetry {
          XCTAssertTrue(session.canRetryRecoveryAuthorization)
          XCTAssertFalse(session.canInspect)
          session.presentRecoveryRetryCredentials()
          await session.submit(dummy)
        }
        switch scenario {
        case .connectionLost, .emptyReply, .helperFailure, .manualRecovery:
          guard case .failed(let failure) = session.phase else { return XCTFail(scenario.title) }
          XCTAssertFalse(failure.plainDetail.contains("Nothing was changed"))
          XCTAssertFalse(session.canInspect)
          XCTAssertFalse(session.canRetryRecoveryAuthorization)
          if scenario != .manualRecovery { XCTAssertEqual(session.journal.checkpoints.count, 1) }
        case .completed:
          guard case .done = session.phase else { return XCTFail(scenario.title) }
        default:
          guard case .awaitingRecovery = session.phase else { return XCTFail(scenario.title) }
          if scenario == .success { XCTAssertEqual(session.journal.checkpoints.count, 3) }
          XCTAssertEqual(session.shutDown(), scenario != .shutdownFailure)
          XCTAssertTrue(
            try XCTUnwrap(session.shutdownMessage).contains(
              scenario == .shutdownFailure ? "Simulated shutdown failed" : "Simulation complete"))
        }
      }
    }

    func testFreeExtentCanGrowWithoutChangingMacOSOrTotalCapacity() async throws {
      let environment = InstallerSimulationEnvironment(scenario: .freeSpace, delay: .zero)
      let first = try await environment.preparePlan(omarchyBytes: nil, progress: { _ in })
      let next = try await environment.preparePlan(
        omarchyBytes: 600_000_000_000, progress: { _ in })
      guard case .plan(let initial) = first, case .plan(let larger) = next else {
        return XCTFail("Expected plans")
      }
      XCTAssertEqual(initial.diskTotalBytes, larger.diskTotalBytes)
      XCTAssertEqual(larger.omarchyBytes, 600_000_000_000)
      XCTAssertEqual(larger.macOSBytes(for: larger.omarchyBytes), 100_000_000_000)
      XCTAssertEqual(larger.unallocatedBytes(for: larger.omarchyBytes), 200_000_000_000)
      XCTAssertGreaterThan(larger.maximumBytes, initial.omarchyBytes + 100_000_000_000)
    }

    func testCancelledSimulationCannotPrepareOrExecute() async throws {
      let environment = InstallerSimulationEnvironment(scenario: .success, delay: .zero)
      environment.cancel()
      do {
        _ = try await environment.inspect()
        XCTFail("Cancelled simulation should stop")
      } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRecoveryRetryDoesNotReplayDiskWork() async throws {
      let environment = InstallerSimulationEnvironment(scenario: .recoveryRetry, delay: .zero)
      try environment.approve()
      let result = try await environment.execute(
        operation: .retryRecoveryAuthorization,
        authorization: MachineOwnerAuthorization(
          username: "simulation", password: Data("dummy".utf8)),
        journal: { _ in XCTFail("Recovery retry must not simulate another disk write") })
      XCTAssertEqual(result.nextAction, .enterRecovery)
    }
  }
#endif
