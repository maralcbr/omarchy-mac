#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore
  import XCTest

  @testable import OmarchyInstallerUXCore

  final class PlainLanguageTests: XCTestCase {
    func testEveryPhaseHasADistinctTitle() {
      let phases = [
        "preflight", "existing_removal", "apfs_preparation", "stub_and_esp",
        "awaiting_recovery", "boot_policy", "media_handoff", "omarchy_install",
      ]
      let titles = phases.map { PlainLanguage.installPhaseTitle(forPhase: $0) }

      XCTAssertEqual(Set(titles).count, phases.count)
      XCTAssertTrue(titles.allSatisfy { !$0.isEmpty })
      XCTAssertEqual(
        PlainLanguage.installPhaseTitle(forPhase: nil),
        PlainLanguage.installVerifyingOwner
      )
    }

    func testEveryStartedEventHasATitle() {
      for event in [
        "existing_removal_started", "apfs_preparation_started",
        "stub_and_esp_started", "recovery_handoff_started",
      ] {
        XCTAssertNotNil(PlainLanguage.installPhaseTitle(forEvent: event))
        XCTAssertFalse(PlainLanguage.eventSummary(event).isEmpty)
      }
      XCTAssertNil(PlainLanguage.installPhaseTitle(forEvent: "unknown_event"))
      XCTAssertEqual(PlainLanguage.eventSummary("odd_name"), "odd name")
    }

    func testEveryCheckpointHasAPlainSummary() {
      let identifiers = [
        "existing-install-removed", "apfs-target-prepared",
        "stub-and-esp-installed", "recovery-handoff-prepared",
      ]
      let summaries = identifiers.map(PlainLanguage.checkpointSummary)

      XCTAssertEqual(Set(summaries).count, identifiers.count)
      XCTAssertTrue(summaries.allSatisfy { !$0.isEmpty })
      XCTAssertEqual(PlainLanguage.checkpointSummary("unknown"), "unknown")
    }

    func testEveryNextActionHasAMessage() {
      let actions: [InstallerNextAction] = [
        .continueInstallation, .enterRecovery, .attachInstallationMedia,
        .verifyInstalledSystem, .manualRecovery,
      ]
      let messages = actions.map(PlainLanguage.nextActionMessage)

      XCTAssertEqual(Set(messages).count, actions.count)
      XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
    }

    func testRecoveryStepsCoverSignedTokensAndUnknowns() {
      let steps = PlainLanguage.recoverySteps(for: [
        "enterOneTrueRecovery", "authenticateMachineOwner",
      ])
      XCTAssertEqual(steps.count, 3)
      XCTAssertEqual(steps.map(\.number), [1, 2, 3])

      let unknown = PlainLanguage.recoverySteps(for: ["somethingNew"])
      XCTAssertEqual(unknown.count, 1)
      XCTAssertEqual(unknown.first?.title, "somethingNew")

      XCTAssertEqual(PlainLanguage.recoverySteps(for: []).count, 3)
    }

    func testKnownErrorsMapToDistinctHeadlinesAndKeepTechnicalDetail() {
      let errors: [any Error] = [
        EngineXPCSubmissionError.machineOwnerCredentialsRejected,
        EngineXPCSubmissionError.connectionFailed,
        EngineXPCSubmissionError.recoveryAuthorizationFailed,
        ClosedEngineHelperError.busy,
        ClosedEngineHelperError.unsupportedDevice("apple,j614s"),
        InstallerPlanPreparationError.inventoryUnavailable,
        ArtifactStageError.digestMismatch(expected: "a", actual: "b"),
        InstallerReleaseConfigurationError.releaseResourcesUnavailable,
        SupportCatalogError.expired,
        InstallerAssetPreparationError.hostBlocked("not enabled"),
        InstallerAssetPreparationError.unsupportedDevice("apple,j614s"),
        InstallerAssetPreparationError.deliveryMetadataUnavailable,
        InstallerAppErrorStub.unknown,
      ]

      var headlines = Set<String>()
      for error in errors {
        let failure = PlainLanguage.failure(for: error)
        XCTAssertFalse(failure.headline.isEmpty)
        XCTAssertFalse(failure.plainDetail.isEmpty)
        XCTAssertEqual(failure.technicalDetail, String(describing: error))
        headlines.insert(failure.headline)
      }
      XCTAssertGreaterThanOrEqual(headlines.count, 8)
    }

    func testAnOutdatedInstallerOffersTheDownloadItNeeds() {
      let url = URL(
        string: "https://downloads.example.com/installer/stable/Installer.pkg"
      )!
      let failure = PlainLanguage.failure(
        for: InstallerAssetPreparationError.installerOutdated(
          current: InstallerVersion("1.9.9")!,
          minimum: InstallerVersion("2.0.0")!,
          downloadURL: url
        )
      )

      XCTAssertEqual(failure.headline, "This installer is out of date")
      XCTAssertTrue(failure.plainDetail.contains("2.0.0"))
      XCTAssertTrue(failure.plainDetail.contains("1.9.9"))
      XCTAssertTrue(failure.plainDetail.contains("Nothing was downloaded"))
      XCTAssertEqual(failure.actionURL, url)
      XCTAssertEqual(failure.actionTitle, PlainLanguage.downloadInstaller)
      XCTAssertFalse(failure.retryRecoveryAvailable)
    }

    func testFailuresWithoutAnActionCarryNoLink() {
      let failure = PlainLanguage.failure(for: SupportCatalogError.expired)

      XCTAssertNil(failure.actionURL)
      XCTAssertNil(failure.actionTitle)
    }

    func testAnEmptyChannelSaysSoInsteadOfShowingAStatusCode() {
      let failure = PlainLanguage.failure(
        for: InstallerReleaseConfigurationError.unexpectedHTTPStatus(404)
      )

      XCTAssertEqual(failure.headline, "No Omarchy release was found")
      XCTAssertTrue(failure.plainDetail.contains("nothing published"))
      XCTAssertFalse(failure.plainDetail.contains("404"))
      XCTAssertFalse(failure.headline.contains("404"))
      XCTAssertEqual(
        failure.technicalDetail,
        String(describing: InstallerReleaseConfigurationError.unexpectedHTTPStatus(404))
      )
      XCTAssertTrue(try XCTUnwrap(failure.remedy).contains("Release Channel"))
    }

    func testOtherServerFailuresAreDistinctFromAnEmptyChannel() {
      let failure = PlainLanguage.failure(
        for: InstallerReleaseConfigurationError.unexpectedHTTPStatus(503)
      )

      XCTAssertEqual(failure.headline, "The release server did not answer properly")
      XCTAssertFalse(failure.plainDetail.contains("503"))
    }

    func testAnUnreadableReleaseIsExplainedPlainly() {
      let failure = PlainLanguage.failure(
        for: InstallerReleaseConfigurationError.invalidCatalogEnvelope
      )

      XCTAssertEqual(failure.headline, "The published release could not be read")
    }

    func testRetryEligibleFailureIsFlaggedAndExplained() {
      let failure = PlainLanguage.failure(
        for: EngineXPCSubmissionError.recoveryAuthorizationFailed,
        retryRecoveryAvailable: true
      )

      XCTAssertTrue(failure.retryRecoveryAvailable)
      XCTAssertEqual(failure.headline, "Recovery authorization didn’t complete")
      XCTAssertNotNil(failure.remedy)
      XCTAssertNotNil(failure.technicalDetail)
    }

    func testBlockedDeviceIsFlaggedAsBlockedModel() {
      let failure = PlainLanguage.failure(
        for: ClosedEngineHelperError.unsupportedDevice("apple,j614s")
      )

      XCTAssertTrue(failure.isBlockedModel)
      XCTAssertEqual(failure.headline, PlainLanguage.blockedHeadline)
    }

    func testDigestShorteningKeepsBothEnds() {
      let digest = "sha256:" + String(repeating: "a", count: 56) + "beefcafe"

      let short = PlainLanguage.shortDigest(digest)

      XCTAssertTrue(short.hasPrefix("aaaaaaaa"))
      XCTAssertTrue(short.hasSuffix("beefcafe"))
      XCTAssertTrue(short.contains("…"))
      XCTAssertEqual(PlainLanguage.shortDigest("short"), "short")
    }

    func testByteFormattingIsWholeNumbers() {
      XCTAssertEqual(PlainLanguage.bytes(137_438_953_472), "137 GB")
      XCTAssertEqual(PlainLanguage.bytes(18_400_000), "18 MB")
      XCTAssertEqual(PlainLanguage.bytes(512), "512 bytes")
    }
  }

  private enum InstallerAppErrorStub: Error {
    case unknown
  }
#endif
