#if os(macOS)
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class AcceptedCatalogIdentityStoreTests: XCTestCase {
    func testMissingStateThenAtomicRoundTrip() throws {
      let directory = try privateDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = AcceptedCatalogIdentityStore(directory: directory, channel: .stable)
      let identity = try catalogIdentity(sequence: 8, digit: "a")

      XCTAssertNil(try store.load())
      try store.store(identity)

      XCTAssertEqual(try store.load(), identity)
      let state = directory.appendingPathComponent(
        AcceptedCatalogIdentityStore.fileName(for: .stable)
      )
      let permissions = try XCTUnwrap(
        try FileManager.default.attributesOfItem(atPath: state.path)[
          .posixPermissions
        ] as? NSNumber
      )
      XCTAssertEqual(permissions.intValue & 0o077, 0)
    }

    func testChannelsKeepIndependentSequences() throws {
      let directory = try privateDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let stable = AcceptedCatalogIdentityStore(
        directory: directory,
        channel: .stable
      )
      let rc = AcceptedCatalogIdentityStore(directory: directory, channel: .rc)

      try rc.store(try catalogIdentity(sequence: 90, digit: "b"))
      // Stable is far behind rc, which must not read as a rollback.
      try stable.store(try catalogIdentity(sequence: 10, digit: "a"))

      XCTAssertEqual(try stable.load()?.sequence, 10)
      XCTAssertEqual(try rc.load()?.sequence, 90)
    }

    func testStableReadsThePreChannelStateFile() throws {
      let directory = try privateDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let identity = try catalogIdentity(sequence: 42, digit: "c")
      try writeLegacyState(identity, in: directory)

      let stable = AcceptedCatalogIdentityStore(
        directory: directory,
        channel: .stable
      )

      XCTAssertEqual(try stable.load(), identity)
    }

    func testBetaIgnoresThePreChannelStateFile() throws {
      let directory = try privateDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      try writeLegacyState(
        try catalogIdentity(sequence: 42, digit: "c"),
        in: directory
      )

      let rc = AcceptedCatalogIdentityStore(directory: directory, channel: .rc)

      XCTAssertNil(try rc.load())
    }

    func testTheFirstStableWriteRetiresThePreChannelStateFile() throws {
      let directory = try privateDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      try writeLegacyState(
        try catalogIdentity(sequence: 42, digit: "c"),
        in: directory
      )
      let stable = AcceptedCatalogIdentityStore(
        directory: directory,
        channel: .stable
      )

      try stable.store(try catalogIdentity(sequence: 43, digit: "d"))

      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent(
            AcceptedCatalogIdentityStore.legacyFileName
          ).path
        )
      )
      XCTAssertEqual(try stable.load()?.sequence, 43)
    }

    func testASymlinkedPreChannelStateFileIsRejected() throws {
      let directory = try privateDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let external = FileManager.default.temporaryDirectory
        .appendingPathComponent("omarchy-legacy-\(UUID().uuidString).json")
      defer { try? FileManager.default.removeItem(at: external) }
      try Data("{}".utf8).write(to: external, options: .withoutOverwriting)
      try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent(
          AcceptedCatalogIdentityStore.legacyFileName
        ),
        withDestinationURL: external
      )

      XCTAssertThrowsError(
        try AcceptedCatalogIdentityStore(directory: directory, channel: .stable)
          .load()
      ) {
        XCTAssertEqual(
          $0 as? AcceptedCatalogIdentityStoreError,
          .unsafeState
        )
      }
    }

    func testRollbackSequenceIsRejected() throws {
      let directory = try privateDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = AcceptedCatalogIdentityStore(directory: directory, channel: .stable)
      try store.store(try catalogIdentity(sequence: 9, digit: "a"))

      XCTAssertThrowsError(
        try store.store(try catalogIdentity(sequence: 8, digit: "b"))
      ) {
        XCTAssertEqual(
          $0 as? SupportCatalogSequenceError,
          .rollback(stored: 9, candidate: 8)
        )
      }
    }

    func testSequenceReuseWithDifferentPayloadIsRejected() throws {
      let directory = try privateDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = AcceptedCatalogIdentityStore(directory: directory, channel: .stable)
      try store.store(try catalogIdentity(sequence: 9, digit: "a"))

      XCTAssertThrowsError(
        try store.store(try catalogIdentity(sequence: 9, digit: "b"))
      ) {
        XCTAssertEqual(
          $0 as? SupportCatalogSequenceError,
          .sequenceReuse(9)
        )
      }
    }

    func testSymlinkedStateIsRejected() throws {
      let directory = try privateDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let external = directory.deletingLastPathComponent()
        .appendingPathComponent(
          "omarchy-catalog-external-\(UUID().uuidString.lowercased())"
        )
      defer { try? FileManager.default.removeItem(at: external) }
      try Data("{}".utf8).write(
        to: external,
        options: .withoutOverwriting
      )
      try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent(
          AcceptedCatalogIdentityStore.fileName(for: .stable)
        ),
        withDestinationURL: external
      )

      XCTAssertThrowsError(
        try AcceptedCatalogIdentityStore(directory: directory, channel: .stable).load()
      ) {
        XCTAssertEqual(
          $0 as? AcceptedCatalogIdentityStoreError,
          .unsafeState
        )
      }
    }

    private func writeLegacyState(
      _ identity: AcceptedCatalogIdentity,
      in directory: URL
    ) throws {
      let document = """
        {"payload_digest":"\(identity.payloadDigest)","schema_version":1,"sequence":\(identity.sequence)}
        """
      try Data(document.utf8).write(
        to: directory.appendingPathComponent(
          AcceptedCatalogIdentityStore.legacyFileName
        ),
        options: .withoutOverwriting
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: directory.appendingPathComponent(
          AcceptedCatalogIdentityStore.legacyFileName
        ).path
      )
    }

    private func catalogIdentity(
      sequence: UInt64,
      digit: Character
    ) throws -> AcceptedCatalogIdentity {
      try AcceptedCatalogIdentity(
        sequence: sequence,
        payloadDigest: "sha256:" + String(repeating: digit, count: 64)
      )
    }

    private func privateDirectory() throws -> URL {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "omarchy-catalog-store-\(UUID().uuidString.lowercased())",
          isDirectory: true
        )
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      return directory
    }
  }
#endif
