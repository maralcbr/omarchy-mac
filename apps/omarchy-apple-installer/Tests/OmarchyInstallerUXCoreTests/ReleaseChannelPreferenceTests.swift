#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore
  import XCTest

  @testable import OmarchyInstallerUXCore

  final class ReleaseChannelPreferenceTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
      suiteName = "omarchy-channel-\(UUID().uuidString)"
      defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
      defaults.removePersistentDomain(forName: suiteName)
      super.tearDown()
    }

    func testAnUnsetPreferenceUsesTheDescriptorDefault() {
      let preference = ReleaseChannelPreference(defaults: defaults)

      XCTAssertNil(preference.stored)
      XCTAssertEqual(preference.resolve(descriptorDefault: .stable), .stable)
      XCTAssertEqual(preference.resolve(descriptorDefault: .rc), .rc)
    }

    func testSelectingBetaIsRemembered() {
      let preference = ReleaseChannelPreference(defaults: defaults)

      preference.select(.rc)

      XCTAssertEqual(preference.stored, .rc)
      XCTAssertEqual(preference.resolve(descriptorDefault: .stable), .rc)
    }

    func testClearingThePreferenceReturnsToTheDefault() {
      let preference = ReleaseChannelPreference(defaults: defaults)
      preference.select(.rc)

      preference.select(nil)

      XCTAssertNil(preference.stored)
      XCTAssertEqual(preference.resolve(descriptorDefault: .stable), .stable)
    }

    func testAnUnknownStoredValueFallsBackToTheDefault() {
      // A hand-edited or stale preference must never leave the app reading a
      // channel this build does not know.
      defaults.set("nightly", forKey: ReleaseChannelPreference.defaultsKey)
      let preference = ReleaseChannelPreference(defaults: defaults)

      XCTAssertNil(preference.stored)
      XCTAssertEqual(preference.resolve(descriptorDefault: .stable), .stable)
    }
  }
#endif
