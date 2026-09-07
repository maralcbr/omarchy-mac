#if os(macOS)
  import XCTest
  @testable import OmarchyInstallerUXCore

  final class DiskSizeInputTests: XCTestCase {
    func testClickAndApplyPreservesExactExistingBytes() {
      var input = DiskSizeInput()
      input.begin(bytes: 137_438_953_472, minimum: 80_000_000_000, maximum: 700_000_000_000)
      XCTAssertTrue(input.isEditing)
      XCTAssertEqual(input.text, "137")
      XCTAssertEqual(input.apply(), 137_438_953_472)
      XCTAssertFalse(input.isEditing)
    }

    func testWholeGigabytesCanBeApplied() {
      var input = DiskSizeInput()
      input.begin(bytes: 137_438_953_472, minimum: 80_000_000_000, maximum: 700_000_000_000)
      input.text = "250"
      XCTAssertNil(input.validationMessage)
      XCTAssertEqual(input.apply(), 250_000_000_000)
    }

    func testCancelRestoresConfirmedSize() {
      var input = DiskSizeInput()
      input.begin(bytes: 137_438_953_472, minimum: 80_000_000_000, maximum: 700_000_000_000)
      input.text = "600"
      input.cancel()
      XCTAssertEqual(input.text, "137")
      XCTAssertFalse(input.isEditing)
      XCTAssertNil(input.apply())
    }

    func testInvalidInputStaysEditableAndCannotApply() {
      for text in [
        "", "abc", "-1", "NaN", "1e9", "250,5", "79.999", "701", "184467440737095516160",
        "80.0000000001", "250.5", "100000",
      ] {
        var input = DiskSizeInput()
        input.begin(bytes: 137_438_953_472, minimum: 80_000_000_000, maximum: 700_000_000_000)
        input.text = text
        XCTAssertNotNil(input.validationMessage, text)
        XCTAssertNil(input.apply(), text)
        XCTAssertTrue(input.isEditing, text)
      }
    }

    @MainActor
    func testReplanClearsDraftAndAllowsFreshAcknowledgement() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.setSizeEditing(true)
      await session.replan(omarchyBytes: 250_000_000_000)
      XCTAssertFalse(session.isEditingSize)
      XCTAssertFalse(session.isBusy)
      guard case .planReview(_, let acknowledged) = session.phase else {
        return XCTFail("Expected a refreshed plan")
      }
      XCTAssertFalse(acknowledged)
      session.setAcknowledged(true)
      session.approve()
      XCTAssertEqual(environment.approveCount, 1)
    }

    @MainActor
    func testPendingDraftBlocksApprovalAndChannelChange() async {
      let environment = MockInstallerEnvironment()
      let session = InstallerSession(environment: environment)
      await session.inspect()
      await session.continueToPlan()
      session.continueToPlanReview()
      session.setAcknowledged(true)
      session.setSizeEditing(true)
      session.approve()
      XCTAssertEqual(environment.approveCount, 0)
      XCTAssertFalse(session.canChangeChannel)
      session.setSizeEditing(false)
      session.approve()
      XCTAssertEqual(environment.approveCount, 1)
    }
  }
#endif
