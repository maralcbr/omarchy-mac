#if os(macOS)
  import CryptoKit
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class InstallerReleaseConfigurationTests: XCTestCase {
    func testStrictDescriptorLoadsAppOwnedTrustAndHelperIdentity() throws {
      let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
      let fingerprint = digest(key)
      let configuration = try InstallerReleaseConfigurationLoader().load(
        descriptor: descriptor(fingerprint: fingerprint),
        trustRootPublicKey: key
      )

      XCTAssertEqual(
        configuration.catalogURL(for: .stable).absoluteString,
        "https://releases.omarchy.example/channels/stable/catalog.signed.json"
      )
      XCTAssertEqual(
        configuration.catalogURL(for: .rc).absoluteString,
        "https://releases.omarchy.example/channels/rc/catalog.signed.json"
      )
      XCTAssertEqual(configuration.defaultChannel, .stable)
      XCTAssertEqual(configuration.trustRoot.fingerprint, fingerprint)
      XCTAssertEqual(
        configuration.helperMachServiceName,
        InstallerProductIdentity.helperMachServiceName
      )
    }

    func testSchemaOneDescriptorIsRejected() throws {
      let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
      let legacy = Data(
        """
        {"schema_version":1,"catalog_url":"https://releases.omarchy.example/apple/catalog.json","catalog_signature_url":"https://releases.omarchy.example/apple/catalog.json.sig","trust_root_fingerprint":"\(digest(key))","helper_mach_service_name":"com.omarchy.mx.installer.helper","helper_code_signing_requirement":"identifier \\"com.omarchy.mx.installer.helper\\""}
        """.utf8
      )

      XCTAssertThrowsError(
        try InstallerReleaseConfigurationLoader().load(
          descriptor: legacy,
          trustRootPublicKey: key
        )
      ) {
        XCTAssertEqual(
          $0 as? InstallerReleaseConfigurationError,
          .invalidDescriptor
        )
      }
    }

    func testDescriptorsMissingAChannelFailClosed() throws {
      try assertDescriptorRejected { value in
        value["channels"] = [
          "stable": ["catalog_url": "https://releases.omarchy.example/s.json"]
        ]
      }
    }

    func testDescriptorsWithAnUnknownChannelFailClosed() throws {
      try assertDescriptorRejected { value in
        var channels = value["channels"] as! [String: Any]
        channels["nightly"] = [
          "catalog_url": "https://releases.omarchy.example/n.json"
        ]
        value["channels"] = channels
      }
    }

    func testDescriptorsWithAnUnknownChannelFieldFailClosed() throws {
      try assertDescriptorRejected { value in
        var channels = value["channels"] as! [String: Any]
        channels["rc"] = [
          "catalog_url": "https://releases.omarchy.example/b.json",
          "catalog_signature_url": "https://releases.omarchy.example/b.sig",
        ]
        value["channels"] = channels
      }
    }

    func testAnUnknownDefaultChannelFailsClosed() throws {
      try assertDescriptorRejected { value in
        value["default_channel"] = "nightly"
      }
    }

    func testIdenticalChannelURLsFailClosed() throws {
      let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
      var value = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: descriptor(fingerprint: digest(key))
        ) as? [String: Any]
      )
      let shared = "https://releases.omarchy.example/channels/stable/catalog.signed.json"
      value["channels"] = [
        "stable": ["catalog_url": shared],
        "rc": ["catalog_url": shared],
      ]
      let altered = try JSONSerialization.data(withJSONObject: value)

      XCTAssertThrowsError(
        try InstallerReleaseConfigurationLoader().load(
          descriptor: altered,
          trustRootPublicKey: key
        )
      ) {
        XCTAssertEqual(
          $0 as? InstallerReleaseConfigurationError,
          .invalidURL("channels")
        )
      }
    }

    func testAPlainHTTPChannelURLFailsClosed() throws {
      let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
      var value = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: descriptor(fingerprint: digest(key))
        ) as? [String: Any]
      )
      value["channels"] = [
        "stable": ["catalog_url": "http://releases.omarchy.example/s.json"],
        "rc": ["catalog_url": "https://releases.omarchy.example/b.json"],
      ]
      let altered = try JSONSerialization.data(withJSONObject: value)

      XCTAssertThrowsError(
        try InstallerReleaseConfigurationLoader().load(
          descriptor: altered,
          trustRootPublicKey: key
        )
      ) {
        XCTAssertEqual(
          $0 as? InstallerReleaseConfigurationError,
          .invalidURL("channels.stable.catalog_url")
        )
      }
    }

    func testUnknownDescriptorFieldFailsClosed() throws {
      let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
      var value = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: descriptor(fingerprint: digest(key))
        ) as? [String: Any]
      )
      value["unexpected"] = true
      let altered = try JSONSerialization.data(withJSONObject: value)

      XCTAssertThrowsError(
        try InstallerReleaseConfigurationLoader().load(
          descriptor: altered,
          trustRootPublicKey: key
        )
      ) {
        XCTAssertEqual(
          $0 as? InstallerReleaseConfigurationError,
          .invalidDescriptor
        )
      }
    }

    func testTrustRootSubstitutionFailsClosed() throws {
      let expected = Curve25519.Signing.PrivateKey()
        .publicKey.rawRepresentation
      let substituted = Curve25519.Signing.PrivateKey()
        .publicKey.rawRepresentation

      XCTAssertThrowsError(
        try InstallerReleaseConfigurationLoader().load(
          descriptor: descriptor(fingerprint: digest(expected)),
          trustRootPublicKey: substituted
        )
      ) {
        XCTAssertEqual(
          $0 as? InstallerReleaseConfigurationError,
          .invalidTrustRoot
        )
      }
    }

    func testUnexpectedHelperMachServiceFailsClosed() throws {
      let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
      var value = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: descriptor(fingerprint: digest(key))
        ) as? [String: Any]
      )
      value["helper_mach_service_name"] = "com.example.other.helper"
      let altered = try JSONSerialization.data(withJSONObject: value)

      XCTAssertThrowsError(
        try InstallerReleaseConfigurationLoader().load(
          descriptor: altered,
          trustRootPublicKey: key
        )
      ) {
        XCTAssertEqual(
          $0 as? InstallerReleaseConfigurationError,
          .invalidHelperIdentity
        )
      }
    }

    func testChannelEnvelopeDownloadsAndDecodes() async throws {
      let configuration = try configuration()
      let catalog = Data("signed catalog".utf8)
      let signature = Data(repeating: 7, count: 64)
      let fetcher = InstallerReleaseCatalogFetcher(
        downloader: FixtureReleaseDownloader(values: [
          configuration.catalogURL(for: .stable): envelope(
            catalog: catalog,
            signature: signature
          )
        ])
      )

      let result = try await fetcher.fetch(
        configuration: configuration,
        channel: .stable
      )

      XCTAssertEqual(result.payload, catalog)
      XCTAssertEqual(result.signature, signature)
    }

    func testBetaChannelReadsTheBetaObject() async throws {
      let configuration = try configuration()
      let catalog = Data("rc catalog".utf8)
      let signature = Data(repeating: 4, count: 64)
      let fetcher = InstallerReleaseCatalogFetcher(
        downloader: FixtureReleaseDownloader(values: [
          configuration.catalogURL(for: .rc): envelope(
            catalog: catalog,
            signature: signature
          )
        ])
      )

      let result = try await fetcher.fetch(
        configuration: configuration,
        channel: .rc
      )

      XCTAssertEqual(result.payload, catalog)
    }

    func testShortCatalogSignatureFailsClosed() async throws {
      let configuration = try configuration()
      let fetcher = InstallerReleaseCatalogFetcher(
        downloader: FixtureReleaseDownloader(values: [
          configuration.catalogURL(for: .stable): envelope(
            catalog: Data("catalog".utf8),
            signature: Data(repeating: 3, count: 63)
          )
        ])
      )

      await assertThrowsErrorAsync(
        try await fetcher.fetch(configuration: configuration, channel: .stable)
      ) {
        XCTAssertEqual(
          $0 as? InstallerReleaseConfigurationError,
          .invalidCatalogSignature
        )
      }
    }

    func testMalformedEnvelopesFailClosed() async throws {
      let configuration = try configuration()
      let signature = Data(repeating: 7, count: 64).base64EncodedString()
      let bodies = [
        #"{"schema_version":1,"catalog":"!!not base64!!","signature":"\#(signature)"}"#,
        #"{"schema_version":2,"catalog":"Y2F0YWxvZw==","signature":"\#(signature)"}"#,
        #"{"schema_version":1,"catalog":"Y2F0YWxvZw=="}"#,
        #"{"schema_version":1,"catalog":"Y2F0YWxvZw==","signature":"\#(signature)","extra":1}"#,
        #"{"schema_version":1,"catalog":"","signature":"\#(signature)"}"#,
        "not json at all",
      ]

      for body in bodies {
        let fetcher = InstallerReleaseCatalogFetcher(
          downloader: FixtureReleaseDownloader(values: [
            configuration.catalogURL(for: .stable): Data(body.utf8)
          ])
        )
        await assertThrowsErrorAsync(
          try await fetcher.fetch(
            configuration: configuration,
            channel: .stable
          )
        ) {
          XCTAssertNotNil($0 as? InstallerReleaseConfigurationError, body)
        }
      }
    }

    func testLocatorLoadsStrictFilesFromReleaseDirectory() throws {
      let root = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
      try descriptor(fingerprint: digest(key)).write(
        to: root.appendingPathComponent(
          InstallerReleaseConfigurationLocator.descriptorFileName
        ),
        options: .withoutOverwriting
      )
      try key.write(
        to: root.appendingPathComponent(
          InstallerReleaseConfigurationLocator.trustRootFileName
        ),
        options: .withoutOverwriting
      )

      let result = try InstallerReleaseConfigurationLocator().load(from: root)

      XCTAssertEqual(result.trustRoot.fingerprint, digest(key))
      XCTAssertNil(result.sealedCatalogDocuments)
    }

    func testLocatorLoadsAndFetcherPrefersSealedCatalog() async throws {
      let root = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
      let catalog = Data("sealed signed catalog".utf8)
      let signature = Data(repeating: 9, count: 64)
      try writeReleaseIdentity(key, to: root)
      try catalog.write(
        to: root.appendingPathComponent(
          InstallerReleaseConfigurationLocator.sealedCatalogFileName
        ),
        options: .withoutOverwriting
      )
      try signature.write(
        to: root.appendingPathComponent(
          InstallerReleaseConfigurationLocator
            .sealedCatalogSignatureFileName
        ),
        options: .withoutOverwriting
      )

      let configuration = try InstallerReleaseConfigurationLocator()
        .load(from: root)
      let result = try await InstallerReleaseCatalogFetcher(
        downloader: FixtureReleaseDownloader(values: [:])
      ).fetch(configuration: configuration, channel: .stable)

      XCTAssertEqual(result.payload, catalog)
      XCTAssertEqual(result.signature, signature)
    }

    func testLocatorRejectsIncompleteSealedCatalogPair() throws {
      let root = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
      try writeReleaseIdentity(key, to: root)
      try Data("catalog".utf8).write(
        to: root.appendingPathComponent(
          InstallerReleaseConfigurationLocator.sealedCatalogFileName
        ),
        options: .withoutOverwriting
      )

      XCTAssertThrowsError(
        try InstallerReleaseConfigurationLocator().load(from: root)
      ) {
        XCTAssertEqual(
          $0 as? InstallerReleaseConfigurationError,
          .unsafeReleaseResource("sealed-catalog-pair")
        )
      }
    }

    func testLocatorRejectsSymlinkedTrustRoot() throws {
      let root = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
      try descriptor(fingerprint: digest(key)).write(
        to: root.appendingPathComponent(
          InstallerReleaseConfigurationLocator.descriptorFileName
        ),
        options: .withoutOverwriting
      )
      let external = root.deletingLastPathComponent().appendingPathComponent(
        "omarchy-external-key-\(UUID().uuidString.lowercased())"
      )
      defer { try? FileManager.default.removeItem(at: external) }
      try key.write(to: external, options: .withoutOverwriting)
      try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent(
          InstallerReleaseConfigurationLocator.trustRootFileName
        ),
        withDestinationURL: external
      )

      XCTAssertThrowsError(
        try InstallerReleaseConfigurationLocator().load(from: root)
      ) {
        XCTAssertEqual(
          $0 as? InstallerReleaseConfigurationError,
          .unsafeReleaseResource("trust-root")
        )
      }
    }

    private func configuration() throws -> InstallerReleaseConfiguration {
      let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
      return try InstallerReleaseConfigurationLoader().load(
        descriptor: descriptor(fingerprint: digest(key)),
        trustRootPublicKey: key
      )
    }

    private func assertDescriptorRejected(
      _ mutate: (inout [String: Any]) -> Void,
      file: StaticString = #filePath,
      line: UInt = #line
    ) throws {
      let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
      var value = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: descriptor(fingerprint: digest(key))
        ) as? [String: Any]
      )
      mutate(&value)
      let altered = try JSONSerialization.data(withJSONObject: value)

      XCTAssertThrowsError(
        try InstallerReleaseConfigurationLoader().load(
          descriptor: altered,
          trustRootPublicKey: key
        ),
        file: file,
        line: line
      ) {
        XCTAssertEqual(
          $0 as? InstallerReleaseConfigurationError,
          .invalidDescriptor,
          file: file,
          line: line
        )
      }
    }

    private func envelope(catalog: Data, signature: Data) -> Data {
      Data(
        """
        {"schema_version":1,"catalog":"\(catalog.base64EncodedString())","signature":"\(signature.base64EncodedString())"}
        """.utf8
      )
    }

    private func descriptor(fingerprint: String) -> Data {
      Data(
        """
        {"schema_version":2,"default_channel":"stable","channels":{"stable":{"catalog_url":"https://releases.omarchy.example/channels/stable/catalog.signed.json"},"rc":{"catalog_url":"https://releases.omarchy.example/channels/rc/catalog.signed.json"}},"trust_root_fingerprint":"\(fingerprint)","helper_mach_service_name":"com.omarchy.mx.installer.helper","helper_code_signing_requirement":"identifier \\"com.omarchy.mx.installer.helper\\""}
        """.utf8
      )
    }

    private func writeReleaseIdentity(
      _ key: Data,
      to root: URL
    ) throws {
      try descriptor(fingerprint: digest(key)).write(
        to: root.appendingPathComponent(
          InstallerReleaseConfigurationLocator.descriptorFileName
        ),
        options: .withoutOverwriting
      )
      try key.write(
        to: root.appendingPathComponent(
          InstallerReleaseConfigurationLocator.trustRootFileName
        ),
        options: .withoutOverwriting
      )
    }

    private func digest(_ data: Data) -> String {
      "sha256:"
        + SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
    }

    private func makeDirectory() throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "omarchy-release-config-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      return root
    }
  }

  private struct FixtureReleaseDownloader: ReleaseDocumentDownloading {
    let values: [URL: Data]

    func download(
      from url: URL,
      maximumBytes: Int,
      role: String
    ) async throws -> Data {
      guard let value = values[url],
        !value.isEmpty,
        value.count <= maximumBytes
      else {
        throw InstallerReleaseConfigurationError.oversizedDocument(role)
      }
      return value
    }
  }

  private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (any Error) -> Void = { _ in }
  ) async {
    do {
      _ = try await expression()
      XCTFail("Expected expression to throw")
    } catch {
      errorHandler(error)
    }
  }
#endif
