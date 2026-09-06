#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore
  import XCTest

  @testable import OmarchyInstallerUXCore

  @MainActor
  final class InstallerSessionTests: XCTestCase {
    func testHappyPathFollowsTheTransitionTable() async throws {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)

      await session.inspect()
      guard case .welcome = session.phase else {
        return XCTFail("Expected welcome, got \(session.phase)")
      }

      await session.continueToPlan()
      session.continueToPlanReview()
      guard case .planReview(_, let acknowledged) = session.phase else {
        return XCTFail("Expected planReview, got \(session.phase)")
      }
      XCTAssertFalse(acknowledged)

      session.setAcknowledged(true)
      session.approve()
      guard case .awaitingInstall = session.phase else {
        return XCTFail("Expected awaitingInstall, got \(session.phase)")
      }
      XCTAssertEqual(environment.approveCount, 1)
      XCTAssertTrue(session.canStartInstallation)

      session.presentInstallCredentials()
      XCTAssertNotNil(session.credentialSheet.context)

      await session.submit(try authorization())
      guard case .awaitingRecovery = session.phase else {
        return XCTFail("Expected awaitingRecovery, got \(session.phase)")
      }
      XCTAssertTrue(session.hasExecutionStarted)
      XCTAssertEqual(environment.executeCount, 1)
      XCTAssertEqual(environment.lastOperation, .install)
      XCTAssertNil(session.credentialSheet.context)

      session.shutDown()
      XCTAssertEqual(environment.requestShutdownCount, 1)
      guard case .awaitingRecovery = session.phase else {
        return XCTFail("Expected awaitingRecovery, got \(session.phase)")
      }
    }

    func testBlockedHostLocksToUnsupported() async {
      let environment = MockInstallerEnvironment()
      environment.installationBlocked = true
      environment.host = MockInstallerEnvironment.blockedHost
      let session = InstallerSession(environment: environment)

      await session.inspect()

      guard case .unsupported(let failure) = session.phase else {
        return XCTFail("Expected unsupported, got \(session.phase)")
      }
      XCTAssertTrue(failure.isBlockedModel)
      XCTAssertTrue(session.installationBlocked)
      XCTAssertFalse(session.canStartInstallation)

      // Locked: nothing but re-inspection moves the phase.
      await session.continueToPlan()
      session.continueToPlanReview()
      guard case .unsupported = session.phase else {
        return XCTFail("Blocked host must stay locked")
      }
    }

    func testUnsupportedEngineExplainsItselfWithoutClaimingABlockedModel() async {
      let environment = MockInstallerEnvironment()
      environment.host = HostDisplay(
        chipAndSpace: "Apple M1 Pro · 464 GB free",
        supported: false,
        blockingReason: PlainLanguage.engineUnavailable
      )
      let session = InstallerSession(environment: environment)

      await session.inspect()

      guard case .unsupported(let failure) = session.phase else {
        return XCTFail("Expected unsupported, got \(session.phase)")
      }
      XCTAssertFalse(failure.isBlockedModel)
      XCTAssertEqual(failure.headline, PlainLanguage.notReadyHeadline)
      XCTAssertEqual(failure.plainDetail, PlainLanguage.engineUnavailable)
    }

    func testPreparationHoldsUntilContinue() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()

      guard case .planPrepared(_, let update) = session.phase else {
        return XCTFail("Expected planPrepared, got \(session.phase)")
      }
      XCTAssertTrue(update.rows.allSatisfy { $0.phase == .verified })
      session.approve()
      XCTAssertEqual(environment.approveCount, 0)

      session.continueToPlanReview()
      guard case .planReview(_, let acknowledged) = session.phase else {
        return XCTFail("Expected planReview, got \(session.phase)")
      }
      XCTAssertFalse(acknowledged)
    }

    func testReplanCarriesTheChosenSizeAndSkipsTheHold() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()

      await session.replan(omarchyBytes: 200_000_000_000)

      XCTAssertEqual(environment.lastOmarchyBytes, 200_000_000_000)
      XCTAssertEqual(environment.prepareCount, 2)
      guard case .planReview(_, let acknowledged) = session.phase else {
        return XCTFail("Expected planReview after replan, got \(session.phase)")
      }
      XCTAssertFalse(acknowledged)
    }

    func testReplanRequiresFreshAcknowledgementEvenWhenAllocationIsUnchanged() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)

      await session.replan(omarchyBytes: 200_000_000_000)

      guard case .planReview(_, let acknowledged) = session.phase else {
        return XCTFail("Expected planReview after replan, got \(session.phase)")
      }
      XCTAssertFalse(acknowledged)
      XCTAssertEqual(session.planRevision, 2)
      XCTAssertNotNil(session.allocationNotice)
      session.approve()
      XCTAssertEqual(environment.approveCount, 0)
    }

    func testApproveRequiresAcknowledgement() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()

      session.approve()

      XCTAssertEqual(environment.approveCount, 0)
      guard case .planReview = session.phase else {
        return XCTFail("Expected to stay in planReview")
      }
    }

    func testIllegalTransitionsAreNoOps() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)

      // Before inspection completes nothing may advance.
      session.approve()
      session.setAcknowledged(true)
      session.presentInstallCredentials()
      session.refreshHelperStatus()
      await session.continueToPlan()
      session.continueToPlanReview()

      XCTAssertEqual(environment.approveCount, 0)
      XCTAssertEqual(environment.prepareCount, 0)
      guard case .inspecting = session.phase else {
        return XCTFail("Expected inspecting, got \(session.phase)")
      }
    }

    func testCredentialRejectionReopensTheSheet() async throws {
      let environment = MockInstallerEnvironment()
      environment.executeResults = [
        .failure(EngineXPCSubmissionError.machineOwnerCredentialsRejected),
        .success(MockInstallerEnvironment.recoveryCompletion),
      ]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()

      await session.submit(try authorization())

      guard case .awaitingInstall(_, _, let sheet) = session.phase else {
        return XCTFail("Expected awaitingInstall, got \(session.phase)")
      }
      XCTAssertEqual(sheet.context?.error, .credentialsRejected)
      // The helper rejects credentials before any work starts, so the one-shot
      // latch is released for a second attempt.
      XCTAssertFalse(session.hasExecutionStarted)
      XCTAssertTrue(session.canStartInstallation)

      await session.submit(try authorization())
      guard case .awaitingRecovery = session.phase else {
        return XCTFail("Expected awaitingRecovery, got \(session.phase)")
      }
      XCTAssertEqual(environment.executeCount, 2)
    }

    func testNonCredentialFailureKeepsTheOneShotLatch() async throws {
      let environment = MockInstallerEnvironment()
      environment.executeResults = [
        .failure(EngineXPCSubmissionError.connectionFailed)
      ]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()

      await session.submit(try authorization())

      guard case .failed(let failure) = session.phase else {
        return XCTFail("Expected failed, got \(session.phase)")
      }
      XCTAssertFalse(failure.retryRecoveryAvailable)
      XCTAssertTrue(session.hasExecutionStarted)
      XCTAssertNotNil(failure.technicalDetail)
    }

    func testRecoveryRetryIsOnlyReachableWhenEligible() async throws {
      let environment = MockInstallerEnvironment()
      environment.executeResults = [
        .failure(EngineXPCSubmissionError.recoveryAuthorizationFailed),
        .success(MockInstallerEnvironment.recoveryCompletion),
      ]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()
      await session.submit(try authorization())

      guard case .failed(let failure) = session.phase else {
        return XCTFail("Expected failed, got \(session.phase)")
      }
      XCTAssertTrue(failure.retryRecoveryAvailable)
      XCTAssertTrue(session.canRetryRecoveryAuthorization)

      session.presentRecoveryRetryCredentials()
      XCTAssertEqual(
        session.credentialSheet.context?.kind,
        .retryRecoveryAuthorization
      )

      await session.submit(try authorization())
      XCTAssertEqual(environment.lastOperation, .retryRecoveryAuthorization)
      guard case .awaitingRecovery = session.phase else {
        return XCTFail("Expected awaitingRecovery, got \(session.phase)")
      }
    }

    func testRetrySheetStaysClosedWithoutEligibility() async throws {
      let environment = MockInstallerEnvironment()
      environment.executeResults = [
        .failure(EngineXPCSubmissionError.connectionFailed)
      ]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()
      await session.submit(try authorization())

      session.presentRecoveryRetryCredentials()

      XCTAssertNil(session.credentialSheet.context)
      XCTAssertFalse(session.canRetryRecoveryAuthorization)
    }

    func testHelperMustBeReachableBeforeInstallationCanStart() async {
      let environment = MockInstallerEnvironment()
      environment.helper = HelperDisplay(status: .notInstalled)
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.approve()

      XCTAssertFalse(session.canStartInstallation)
      session.presentInstallCredentials()
      XCTAssertNil(session.credentialSheet.context)

      // The installer package installs the system daemon; refreshing picks it
      // up. There is no registration or Login Items approval step.
      environment.helper = HelperDisplay(status: .enabled)
      session.refreshHelperStatus()
      XCTAssertTrue(session.canStartInstallation)
    }

    func testJournalChunksDriveTheInstallingDisplay() async throws {
      let environment = MockInstallerEnvironment()
      environment.journalChunks = try JournalFixture.lines()
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.approve()
      session.presentInstallCredentials()

      await session.submit(try authorization())

      XCTAssertEqual(
        session.journal.checkpoints.map(\.identifier),
        [
          "apfs-target-prepared", "stub-and-esp-installed",
          "recovery-handoff-prepared",
        ]
      )
      XCTAssertFalse(session.journal.degraded)
    }

    func testDownloadProgressIsKeyedByRole() async {
      let environment = MockInstallerEnvironment()
      environment.progressUpdates = [
        AssetProgressUpdate(
          stage: .downloading,
          rows: [
            AssetProgressRow(
              role: "payload",
              fileName: "payload.zip",
              bytesCompleted: 10,
              totalBytes: 100,
              phase: .downloading
            )
          ]
        ),
        AssetProgressUpdate(
          stage: .downloading,
          rows: [
            AssetProgressRow(
              role: "payload",
              fileName: "payload.zip",
              bytesCompleted: 100,
              totalBytes: 100,
              phase: .verified
            ),
            AssetProgressRow(
              role: "engine",
              fileName: "engine.tar.gz",
              bytesCompleted: 5,
              totalBytes: 20,
              phase: .downloading
            ),
          ]
        ),
      ]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()

      XCTAssertEqual(session.stagingProgress["payload"]?.phase, .verified)
      XCTAssertEqual(session.stagingProgress["payload"]?.bytesCompleted, 100)
      XCTAssertEqual(session.stagingProgress["engine"]?.bytesCompleted, 5)
    }

    func testReInspectionCannotClearAnExecutionLatch() async throws {
      let environment = MockInstallerEnvironment()
      environment.executeResults = [.failure(EngineXPCSubmissionError.recoveryAuthorizationFailed)]
      let session = await ready(environment)
      session.presentInstallCredentials()
      await session.submit(try authorization())
      let phase = session.phase
      let discards = environment.discardCount
      await session.inspect()
      XCTAssertEqual(session.phase, phase)
      XCTAssertEqual(environment.discardCount, discards)
      XCTAssertTrue(session.hasExecutionStarted)
      XCTAssertTrue(session.recoveryRetryAvailable)
      XCTAssertFalse(session.canChangeChannel)
    }

    func testCancellationAllowsEditingButRevokesApproval() async {
      let environment = MockInstallerEnvironment()
      let session = await ready(environment)
      session.presentInstallCredentials()
      session.dismissCredentials()
      XCTAssertTrue(session.canEditPlan)
      session.editPlan()
      XCTAssertFalse(environment.hasApprovedPlan)
      guard case .planReview(_, let acknowledged) = session.phase else {
        return XCTFail("Expected review")
      }
      XCTAssertFalse(acknowledged)
      XCTAssertFalse(session.canStartInstallation)
    }

    func testInspectionCannotOverlapInspection() async {
      let environment = MockInstallerEnvironment()
      let gate = OperationGate()
      environment.inspectGate = gate
      let session = InstallerSession(environment: environment)
      let operation = Task { await session.inspect() }
      await gate.waitUntilEntered()
      let discards = environment.discardCount
      await session.inspect()
      XCTAssertEqual(environment.discardCount, discards)
      XCTAssertFalse(session.canChangeChannel)
      await gate.release()
      await operation.value
      guard case .welcome = session.phase else { return XCTFail("Expected welcome") }
    }

    func testPreparationBlocksResetAndRejectsDelayedProgress() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)
      await session.inspect()
      let gate = OperationGate()
      environment.prepareGate = gate
      let operation = Task { await session.continueToPlan() }
      await gate.waitUntilEntered()
      let discards = environment.discardCount
      await session.inspect()
      XCTAssertEqual(environment.discardCount, discards)
      XCTAssertFalse(session.canChangeChannel)
      await gate.release()
      await operation.value
      session.continueToPlanReview()
      let phase = session.phase
      environment.savedProgress?(AssetProgressUpdate(stage: .downloading))
      await Task.yield()
      XCTAssertEqual(session.phase, phase)
    }

    func testExecutionBlocksResetBackAndDuplicateSubmission() async throws {
      let environment = MockInstallerEnvironment()
      let session = await ready(environment)
      let gate = OperationGate()
      environment.executeGate = gate
      session.presentInstallCredentials()
      let authorization = try authorization()
      let operation = Task { await session.submit(authorization) }
      await gate.waitUntilEntered()
      let phase = session.phase
      let discards = environment.discardCount
      await session.inspect()
      session.editPlan()
      session.dismissCredentials()
      await session.submit(authorization)
      XCTAssertEqual(session.phase, phase)
      XCTAssertEqual(environment.discardCount, discards)
      XCTAssertEqual(environment.executeCount, 1)
      XCTAssertTrue(session.hasExecutionStarted)
      XCTAssertFalse(session.canChangeChannel)
      await gate.release()
      await operation.value
      let terminal = session.phase
      environment.savedJournal?(try JournalFixture.data())
      await Task.yield()
      XCTAssertEqual(session.phase, terminal)
    }

    func testUnknownOutcomesStayLockedWithAndWithoutCheckpointEvidence() async throws {
      let errors: [any Error] = [
        EngineXPCSubmissionError.connectionFailed,
        EngineXPCSubmissionError.emptyResponse,
        EngineXPCSubmissionError.helperRejected(domain: "Executor", code: 1),
      ]
      for error in errors {
        for hasCheckpoint in [false, true] {
          let environment = MockInstallerEnvironment()
          environment.executeResults = [.failure(error)]
          if hasCheckpoint {
            environment.journalChunks = Array(try JournalFixture.lines().prefix(5))
          }
          let session = await ready(environment)
          session.presentInstallCredentials()
          await session.submit(try authorization())
          guard case .failed(let failure) = session.phase else {
            return XCTFail("Expected failure")
          }
          XCTAssertFalse(failure.plainDetail.contains("Nothing was changed"))
          XCTAssertFalse(session.canInspect)
          XCTAssertFalse(session.canRetryRecoveryAuthorization)
          XCTAssertEqual(session.journal.checkpoints.isEmpty, !hasCheckpoint)
        }
      }
    }

    func testShutdownRetainsInstructionsForAcceptedAndFailedRequests() async throws {
      for accepted in [false, true] {
        let environment = MockInstallerEnvironment()
        environment.shutdownAccepted = accepted
        let session = await ready(environment)
        XCTAssertFalse(session.shutDown())
        XCTAssertEqual(environment.requestShutdownCount, 0)
        session.presentInstallCredentials()
        await session.submit(try authorization())
        let phase = session.phase
        XCTAssertEqual(session.shutDown(), accepted)
        XCTAssertEqual(session.phase, phase)
        XCTAssertNotNil(session.shutdownMessage)
        XCTAssertEqual(environment.requestShutdownCount, 1)
      }
    }

    private func ready(_ environment: MockInstallerEnvironment) async -> InstallerSession {
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.approve()
      return session
    }

    func testPreparationFailureSurfacesTechnicalDetail() async {
      let environment = MockInstallerEnvironment()
      environment.prepareError =
        InstallerReleaseConfigurationError
        .releaseResourcesUnavailable
      let session = InstallerSession(environment: environment)
      await session.inspect()

      await session.continueToPlan()
      session.continueToPlanReview()

      guard case .failed(let failure) = session.phase else {
        return XCTFail("Expected failed, got \(session.phase)")
      }
      XCTAssertEqual(failure.plainDetail, PlainLanguage.releaseResourcesUnavailable)
      XCTAssertNotNil(failure.technicalDetail)
    }

    private func authorization() throws -> MachineOwnerAuthorization {
      try MachineOwnerAuthorization(
        username: "owner",
        password: Data("secret".utf8)
      )
    }

    // MARK: Existing install

    func testAnExistingInstallIsRefusedBeforeAnythingIsFetched() async {
      let environment = MockInstallerEnvironment()
      let install = ExistingInstallDisplay(
        sourceIdentifier: "disk0s3",
        sizeDescription: "128 GB"
      )
      environment.host = HostDisplay(
        chipAndSpace: MockInstallerEnvironment.supportedHost.chipAndSpace,
        supported: true,
        existingInstalls: [install]
      )
      let session = InstallerSession(environment: environment)
      await session.inspect()

      guard case .existingInstallRefused(let host) = session.phase else {
        return XCTFail("Expected existingInstallRefused, got \(session.phase)")
      }
      XCTAssertEqual(host.existingInstalls, [install])
      // Nothing was planned, so nothing was fetched.
      XCTAssertEqual(environment.prepareCount, 0)

      await session.continueToPlan()
      session.setAcknowledged(true)
      session.approve()
      guard case .existingInstallRefused = session.phase else {
        return XCTFail("Expected the refusal to stay, got \(session.phase)")
      }
      XCTAssertEqual(environment.prepareCount, 0)
      XCTAssertFalse(session.canStartInstallation)
    }

    func testAnExistingInstallFoundWhilePlanningIsRefusedToo() async {
      let environment = MockInstallerEnvironment()
      let install = ExistingInstallDisplay(
        sourceIdentifier: "disk0s3",
        sizeDescription: "128 GB"
      )
      environment.existingInstalls = [install]
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()

      guard case .existingInstallRefused = session.phase else {
        return XCTFail("Expected existingInstallRefused, got \(session.phase)")
      }
      XCTAssertEqual(environment.prepareCount, 1)
    }
  }

  actor OperationGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
      entered = true
      await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
      while !entered { await Task.yield() }
    }
    func release() {
      continuation?.resume()
      continuation = nil
    }
  }

  final class MockInstallerEnvironment: InstallerEnvironment, @unchecked Sendable {
    var host = MockInstallerEnvironment.supportedHost
    var plan = MockInstallerEnvironment.samplePlan
    var helper = HelperDisplay(status: .enabled)
    var installationBlocked = false
    var engineSupported = true
    var requestShutdownCount = 0
    var shutdownAccepted = false
    var inspectGate: OperationGate?
    var prepareGate: OperationGate?
    var executeGate: OperationGate?
    var savedProgress: (@Sendable (AssetProgressUpdate) -> Void)?
    var savedJournal: (@Sendable (Data) -> Void)?
    var inspectError: (any Error)?
    var prepareError: (any Error)?
    var approveError: (any Error)?
    var executeResults = [Result<CompletionDisplay, any Error>]()
    var journalChunks = [Data]()
    var progressUpdates = [AssetProgressUpdate]()
    var existingInstalls = [ExistingInstallDisplay]()

    private(set) var approveCount = 0
    private(set) var discardCount = 0
    private(set) var executeCount = 0
    private(set) var prepareCount = 0
    private(set) var lastOperation: InstallOperationKind?
    private var approved = false

    var hasApprovedPlan: Bool { approved }
    var helperStatus: HelperDisplay { helper }

    func inspect() async throws -> HostDisplay {
      await inspectGate?.wait()
      approved = false
      if let inspectError {
        throw inspectError
      }
      return host
    }

    var lastOmarchyBytes: UInt64?

    func preparePlan(
      omarchyBytes: UInt64?,
      progress: @escaping @Sendable (AssetProgressUpdate) -> Void
    ) async throws -> PlanPreparationDisplay {
      savedProgress = progress
      await prepareGate?.wait()
      prepareCount += 1
      lastOmarchyBytes = omarchyBytes
      approved = false
      for update in progressUpdates {
        progress(update)
        await Task.yield()
      }
      if let prepareError {
        throw prepareError
      }
      if !existingInstalls.isEmpty {
        return .existingInstallChoice(existingInstalls)
      }
      return .plan(plan)
    }

    func approve() throws {
      if let approveError {
        throw approveError
      }
      approveCount += 1
      approved = true
    }

    func discardApproval() {
      discardCount += 1
      approved = false
    }

    func refreshHelperStatus() -> HelperDisplay { helper }

    func requestShutdown() -> Bool {
      requestShutdownCount += 1
      return shutdownAccepted
    }

    func execute(
      operation: InstallOperationKind,
      authorization: MachineOwnerAuthorization,
      journal: @escaping @Sendable (Data) -> Void
    ) async throws -> CompletionDisplay {
      executeCount += 1
      savedJournal = journal
      await executeGate?.wait()
      lastOperation = operation
      for chunk in journalChunks {
        journal(chunk)
        await Task.yield()
      }
      // Give the session's main-actor hops a chance to land.
      try? await Task.sleep(for: .milliseconds(20))
      if executeResults.isEmpty {
        return Self.recoveryCompletion
      }
      return try executeResults.removeFirst().get()
    }

    static let supportedHost = HostDisplay(
      chipAndSpace: "Apple M1 Pro · 464 GB free",
      supported: true
    )

    static let blockedHost = HostDisplay(
      chipAndSpace: "Apple M4 · apple,j614s",
      supported: false
    )

    static let samplePlan = PlanDisplay(
      diskTotalBytes: 994_662_584_320,
      omarchyBytes: 137_438_953_472,
      bindingDigest: "sha256:" + String(repeating: "b", count: 64)
    )

    static let recoveryCompletion = CompletionDisplay(
      nextAction: .enterRecovery,
      headline: PlainLanguage.recoveryHeadline,
      subheadline: PlainLanguage.nextActionMessage(.enterRecovery),
      verified: PlainLanguage.doneVerifiedRows,
      handoff: HandoffDisplay(
        headline: PlainLanguage.recoveryHeadline,
        steps: PlainLanguage.recoverySteps(for: [
          "enterOneTrueRecovery", "authenticateMachineOwner",
        ])
      )
    )
  }
#endif
