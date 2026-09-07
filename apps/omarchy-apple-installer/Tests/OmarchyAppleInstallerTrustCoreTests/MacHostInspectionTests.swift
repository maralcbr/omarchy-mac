#if os(macOS)
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class MacHostInspectionTests: XCTestCase {
    func testSupportedM1InspectionRemainsCatalogGated() throws {
      let inspector = makeInspector(target: "J314s")

      let result = try inspector.inspect()

      XCTAssertEqual(result.identity.model, "MacBookPro18,3")
      XCTAssertEqual(result.identity.chip, "Apple M1 Pro")
      XCTAssertEqual(result.identity.deviceIdentifier, "apple,j314s")
      XCTAssertEqual(result.eligibility, .requiresSignedCatalog)
      XCTAssertEqual(result.macOSVersion, "Version 15.6 (Build 24G84)")
      XCTAssertEqual(result.powerSource, .ac)
      XCTAssertTrue(result.fileVaultEnabled)
      XCTAssertEqual(result.storage.containerIdentifier, "disk3")
      XCTAssertEqual(result.storage.physicalStoreIdentifier, "disk0s2")
      XCTAssertEqual(result.storage.shrinkableBytes, 400)
    }

    func testM4InspectionIsBlockedBeforeCatalogOrAuthorization() throws {
      let inspector = makeInspector(
        model: "Mac16,8",
        chip: "Apple M4 Pro",
        target: "J614s"
      )

      let result = try inspector.inspect()

      XCTAssertEqual(result.identity.deviceIdentifier, "apple,j614s")
      XCTAssertEqual(
        result.eligibility,
        .blocked(
          reason: "This installer doesn’t support this Mac model yet."
        )
      )
    }

    func testUnsafeContainerIdentifierStopsBeforeLimitsQuery() {
      let commands = FixtureReadOnlyCommandRunner(
        root: propertyList([
          "APFSContainerReference": "disk3;eraseDisk"
        ]),
        limits: Data(),
        power: Data("Now drawing from 'AC Power'\n".utf8)
      )
      let inspector = AppleSiliconHostInspector(
        hardware: FixtureHardwarePropertyReader(values: [
          "hw.model": "MacBookPro18,3",
          "machdep.cpu.brand_string": "Apple M1 Pro",
          "hw.targettype": "J314s",
        ]),
        commands: commands,
        operatingSystem: FixtureOperatingSystemVersionReader()
      )

      XCTAssertThrowsError(try inspector.inspect()) {
        XCTAssertEqual(
          $0 as? AppleSiliconHostInspectionError,
          .unsafeContainerIdentifier("disk3;eraseDisk")
        )
      }
    }

    func testInvalidTargetTypeFailsClosed() {
      let inspector = makeInspector(target: "J314s;touch")

      XCTAssertThrowsError(try inspector.inspect()) {
        XCTAssertEqual(
          $0 as? AppleSiliconHostInspectionError,
          .invalidHardwareProperty("hw.targettype")
        )
      }
    }

    func testLiveInspectionIsReadOnlyAndReturnsCoherentHostState() throws {
      let result = try AppleSiliconHostInspector().inspect()

      XCTAssertTrue(result.identity.model.hasPrefix("Mac"))
      XCTAssertTrue(result.identity.chip.hasPrefix("Apple M"))
      XCTAssertTrue(result.identity.deviceIdentifier.hasPrefix("apple,j"))
      XCTAssertFalse(result.macOSVersion.isEmpty)
      XCTAssertTrue(result.storage.isInternal)
      XCTAssertGreaterThan(result.storage.containerSizeBytes, 0)
      XCTAssertLessThanOrEqual(
        result.storage.minimumPreferredSizeBytes,
        result.storage.containerSizeBytes
      )
    }

    private func makeInspector(
      model: String = "MacBookPro18,3",
      chip: String = "Apple M1 Pro",
      target: String
    ) -> AppleSiliconHostInspector {
      AppleSiliconHostInspector(
        hardware: FixtureHardwarePropertyReader(values: [
          "hw.model": model,
          "machdep.cpu.brand_string": chip,
          "hw.targettype": target,
        ]),
        commands: FixtureReadOnlyCommandRunner(
          root: propertyList([
            "APFSContainerReference": "disk3",
            "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]],
            "APFSContainerSize": 1_000,
            "APFSContainerFree": 500,
            "Internal": true,
            "FileVault": true,
          ]),
          limits: propertyList(["MinimumSizePreferred": 600]),
          power: Data("Now drawing from 'AC Power'\n".utf8)
        ),
        operatingSystem: FixtureOperatingSystemVersionReader()
      )
    }
  }

  private struct FixtureHardwarePropertyReader: HardwarePropertyReading {
    let values: [String: String]

    func string(named name: String) throws -> String {
      guard let value = values[name] else {
        throw AppleSiliconHostInspectionError.hardwarePropertyUnavailable(name)
      }
      return value
    }
  }

  private struct FixtureReadOnlyCommandRunner: ReadOnlyMacCommandRunning {
    let root: Data
    let limits: Data
    let power: Data

    func run(_ command: ReadOnlyMacCommand) throws -> Data {
      switch command {
      case .rootDiskInfo:
        root
      case .apfsResizeLimits:
        limits
      case .powerSource:
        power
      }
    }
  }

  private struct FixtureOperatingSystemVersionReader:
    OperatingSystemVersionReading
  {
    func versionString() -> String {
      "Version 15.6 (Build 24G84)"
    }
  }

  private func propertyList(_ values: [String: Any]) -> Data {
    try! PropertyListSerialization.data(
      fromPropertyList: values,
      format: .xml,
      options: 0
    )
  }
#endif
