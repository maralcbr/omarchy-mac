import XCTest

@testable import OmarchyAppleInstallerTrustCore

final class InstallerVersionTests: XCTestCase {
  func testParsesThreeComponentVersions() {
    let version = InstallerVersion("2.10.3")
    XCTAssertEqual(version?.major, 2)
    XCTAssertEqual(version?.minor, 10)
    XCTAssertEqual(version?.patch, 3)
    XCTAssertEqual(version?.description, "2.10.3")
  }

  func testRejectsAnythingOtherThanThreeNumericComponents() {
    for value in [
      "2.0", "2.0.0.0", "v2.0.0", "2.0.0-rc", "2..0", "", "a.b.c", " 2.0.0",
      "2.0.0 ", "2.0.+0", "01.0.0", "2.0.007",
    ] {
      XCTAssertNil(InstallerVersion(value), "accepted \(value)")
    }
  }

  func testAcceptsAZeroComponent() {
    XCTAssertNotNil(InstallerVersion("0.0.0"))
    XCTAssertEqual(InstallerVersion("0.1.0")?.description, "0.1.0")
  }

  func testOrdersNumericallyNotLexically() {
    let versions = ["2.0.0", "10.0.0", "2.10.0", "2.2.0", "1.99.99"]
      .compactMap(InstallerVersion.init)
      .sorted()
    XCTAssertEqual(
      versions.map(\.description),
      ["1.99.99", "2.0.0", "2.2.0", "2.10.0", "10.0.0"]
    )
  }

  func testEqualVersionsCompareEqual() {
    XCTAssertEqual(InstallerVersion("2.0.0"), InstallerVersion("2.0.0"))
    XCTAssertTrue(InstallerVersion("2.0.0")! >= InstallerVersion("2.0.0")!)
  }

  func testCurrentReadsTheBundleShortVersionString() {
    let bundle = FixtureBundle(version: "2.1.0")
    XCTAssertEqual(
      InstallerVersion.current(bundle: bundle),
      InstallerVersion("2.1.0")
    )
  }

  func testCurrentIsNilWhenTheBundleHasNoVersion() {
    XCTAssertNil(InstallerVersion.current(bundle: FixtureBundle(version: nil)))
  }

  func testCurrentIsNilWhenTheBundleVersionIsMalformed() {
    XCTAssertNil(
      InstallerVersion.current(bundle: FixtureBundle(version: "4.0.2-mac.1.19"))
    )
  }
}

/// A bundle whose only interesting behaviour is the version it reports, so the
/// unbundled SwiftPM case can be exercised without a real app bundle.
private final class FixtureBundle: Bundle, @unchecked Sendable {
  private let version: String?

  init(version: String?) {
    self.version = version
    super.init()
  }

  override func object(forInfoDictionaryKey key: String) -> Any? {
    guard key == "CFBundleShortVersionString" else {
      return nil
    }
    return version
  }
}
