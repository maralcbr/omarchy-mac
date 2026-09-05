import CryptoKit
import Foundation
import OmarchyAppleInstallerTrustCore
import XCTest

final class AppleInstallerTrustCoreTests: XCTestCase {
  private let core = AppleInstallerTrustCore()
  private let now = Date(timeIntervalSince1970: 1_788_000_000)

  func testSupportedTranscriptExposesValidatedSummary() throws {
    let result = try core.validateEngineTranscript(Data(makeTranscript().utf8))

    XCTAssertEqual(result.deviceIdentifier, "apple,j314s")
    XCTAssertEqual(result.support, .supported)
    XCTAssertEqual(result.plan?.sourceIdentifier, "disk0s3")
    XCTAssertEqual(result.inventory?.systemStoreIdentifier, "disk0")
    XCTAssertEqual(result.inventory?.candidates.count, 1)
    XCTAssertEqual(result.inventory?.candidates.first?.kind, "free")
    XCTAssertEqual(
      result.plan?.requiredHumanSteps,
      [
        "enterOneTrueRecovery",
        "authenticateMachineOwner",
      ])
    XCTAssertEqual(result.checkpoints.map(\.phase), ["apfs_preparation"])
    XCTAssertEqual(result.completion, .awaitingRecovery)
  }

  func testTranscriptLayoutIdentityIgnoresSafeMinimumSizeDrift() throws {
    let baseline = try core.validateEngineTranscript(Data(makeTranscript().utf8))
    let drifted = try core.validateEngineTranscript(
      Data(makeTranscript(minimumInstallBytes: 67_502_274_560).utf8)
    )

    XCTAssertEqual(baseline.inventory?.layoutDigest, drifted.inventory?.layoutDigest)
    XCTAssertEqual(
      drifted.inventory?.candidates.first?.minimumInstallBytes,
      67_502_274_560
    )
  }

  func testRepairTranscriptBindsExactInstalledIdentity() throws {
    let identityDigest = "sha256:" + String(repeating: "9", count: 64)
    let repairManifestDigest = "sha256:" + String(repeating: "7", count: 64)
    let layoutDigest = lengthPrefixedDigest(
      [
        "disk0", "repair", "disk0s2", "857747943424",
        "137438953472", identityDigest,
      ],
      prefix: "sha256:"
    )
    let requiredHumanSteps = ["authenticateMachineOwner"]
    let planDigest = lengthPrefixedDigest(
      [
        "apple,j314s", "disk0", layoutDigest, "repair", "disk0s2",
        "857747943424", "137438953472", "v0.9.0-omarchy.7",
        "sha256:" + String(repeating: "d", count: 64),
        "sha256:" + String(repeating: "e", count: 64),
        "sha256:" + String(repeating: "f", count: 64),
        repairManifestDigest,
        requiredHumanSteps.joined(separator: ","),
      ],
      prefix: ""
    )
    let transcript =
      [
        #"{"schema_version":1,"sequence":1,"type":"inspection","payload":{"device_identifier":"apple,j314s","support":"supported"}}"#,
        #"{"schema_version":1,"sequence":2,"type":"inventory","payload":{"layout_digest":"\#(layoutDigest)","system_store_identifier":"disk0","candidates":[{"kind":"repair","source_identifier":"disk0s2","offset_bytes":857747943424,"length_bytes":137438953472,"minimum_install_bytes":137438953472,"minimum_container_bytes":0,"identity_digest":"\#(identityDigest)"}]}}"#,
        #"{"schema_version":1,"sequence":3,"type":"plan","payload":{"plan_digest":"\#(planDigest)","device_identifier":"apple,j314s","store_identifier":"disk0","layout_digest":"\#(layoutDigest)","candidate_kind":"repair","source_identifier":"disk0s2","offset_bytes":857747943424,"length_bytes":137438953472,"engine_version":"v0.9.0-omarchy.7","engine_digest":"sha256:\#(String(repeating: "d", count: 64))","metadata_digest":"sha256:\#(String(repeating: "e", count: 64))","payload_digest":"sha256:\#(String(repeating: "f", count: 64))","repair_manifest_digest":"\#(repairManifestDigest)","required_human_steps":["authenticateMachineOwner"]}}"#,
      ].joined(separator: "\n") + "\n"

    let result = try core.validateEngineTranscript(Data(transcript.utf8))

    XCTAssertEqual(
      result.inventory?.candidates.first?.identityDigest,
      identityDigest
    )
    XCTAssertEqual(result.plan?.candidateKind, "repair")
    XCTAssertEqual(result.plan?.repairManifestDigest, repairManifestDigest)
  }

  func testReplaceTranscriptBindsIdentityAndCarriesNoRepairManifest() throws {
    let transcript = makeReplaceTranscript()

    let result = try core.validateEngineTranscript(Data(transcript.utf8))

    XCTAssertEqual(result.plan?.candidateKind, "replace")
    XCTAssertNil(result.plan?.repairManifestDigest)
    XCTAssertEqual(result.plan?.lengthBytes, 137_438_953_472)
    XCTAssertEqual(
      result.inventory?.candidates.first?.identityDigest,
      "sha256:" + String(repeating: "9", count: 64)
    )
    XCTAssertEqual(
      result.plan?.requiredHumanSteps,
      [
        "enterOneTrueRecovery",
        "authenticateMachineOwner",
      ])
  }

  func testReplaceTranscriptRejectsRepairManifestDigest() {
    let transcript = makeReplaceTranscript(
      repairManifestDigest: "sha256:" + String(repeating: "7", count: 64)
    )

    XCTAssertThrowsError(
      try core.validateEngineTranscript(Data(transcript.utf8))
    ) {
      XCTAssertEqual($0 as? EngineContractError, .unknownFields(3))
    }
  }

  func testReplaceTranscriptRejectsShrunkenExtent() {
    let transcript = makeReplaceTranscript(
      planLengthBytes: 137_438_953_472 - 1_048_576
    )

    XCTAssertThrowsError(
      try core.validateEngineTranscript(Data(transcript.utf8))
    ) {
      XCTAssertEqual($0 as? EngineContractError, .invalidDigest(3))
    }
  }

  func testReplaceCandidateRejectsMissingIdentityDigest() {
    let transcript = makeReplaceTranscript(includeIdentityDigest: false)

    XCTAssertThrowsError(
      try core.validateEngineTranscript(Data(transcript.utf8))
    ) {
      XCTAssertEqual($0 as? EngineContractError, .unknownFields(2))
    }
  }

  func testReplaceCandidateRejectsMinimumAboveItsExtent() {
    let transcript = makeReplaceTranscript(
      minimumInstallBytes: 137_438_953_472 + 1_048_576
    )

    XCTAssertThrowsError(
      try core.validateEngineTranscript(Data(transcript.utf8))
    ) {
      XCTAssertEqual($0 as? EngineContractError, .unsafeExtent(2))
    }
  }

  func testReplaceStageOneTranscriptAcceptsExistingRemovalPhase() throws {
    let transcript = makeReplaceTranscript(stageOneLines: true)

    let result = try core.validateEngineTranscript(Data(transcript.utf8))

    XCTAssertEqual(
      result.checkpoints.map(\.identifier),
      [
        "existing-install-removed",
        "apfs-target-prepared",
        "stub-and-esp-installed",
        "recovery-handoff-prepared",
      ]
    )
    XCTAssertEqual(
      result.checkpoints.map(\.phase),
      [
        "existing_removal",
        "apfs_preparation",
        "stub_and_esp",
        "awaiting_recovery",
      ]
    )
    XCTAssertEqual(result.completion, .awaitingRecovery)
  }

  func testLateCheckpointInAdvancedPhaseIsAccepted() throws {
    let transcript = makeTranscript(trailingCheckpointPhase: "stub_and_esp")

    let result = try core.validateEngineTranscript(Data(transcript.utf8))

    XCTAssertEqual(
      result.checkpoints.map(\.phase),
      ["apfs_preparation", "stub_and_esp"]
    )
  }

  func testRemovalCheckpointAfterLaterPhaseIsPhaseRegression() {
    let transcript = makeTranscript(
      trailingCheckpointPhase: "existing_removal"
    )

    XCTAssertThrowsError(
      try core.validateEngineTranscript(Data(transcript.utf8))
    ) {
      XCTAssertEqual($0 as? EngineContractError, .phaseRegression(6))
    }
  }

  func testM4UnsupportedInspectionRemainsClosed() throws {
    let transcript = """
      {"schema_version":1,"sequence":1,"type":"inspection","payload":{"device_identifier":"apple,j614s","support":"unsupported"}}

      """

    let result = try core.validateEngineTranscript(Data(transcript.utf8))

    XCTAssertEqual(result.deviceIdentifier, "apple,j614s")
    XCTAssertEqual(result.support, .unsupported)
    XCTAssertNil(result.plan)
    XCTAssertTrue(result.checkpoints.isEmpty)
    XCTAssertNil(result.completion)
  }

  func testTranscriptRejectsSkippedSequence() {
    let transcript = makeTranscript().replacingOccurrences(
      of: #""sequence":4,"type":"event""#,
      with: #""sequence":8,"type":"event""#
    )

    XCTAssertThrowsError(
      try core.validateEngineTranscript(Data(transcript.utf8))
    ) {
      XCTAssertEqual(
        $0 as? EngineContractError,
        .invalidSequence(expected: 4, actual: 8)
      )
    }
  }

  func testTranscriptRejectsUnknownPlanField() {
    let transcript = makeTranscript().replacingOccurrences(
      of: #""required_human_steps":["enterOneTrueRecovery","authenticateMachineOwner"]"#,
      with:
        #""required_human_steps":["enterOneTrueRecovery","authenticateMachineOwner"],"whole_disk":true"#
    )

    XCTAssertThrowsError(
      try core.validateEngineTranscript(Data(transcript.utf8))
    ) {
      XCTAssertEqual($0 as? EngineContractError, .unknownFields(3))
    }
  }

  func testTranscriptRejectsStalePlanEvent() {
    let transcript = makeTranscript(
      eventPlanDigest: String(repeating: "c", count: 64)
    )

    XCTAssertThrowsError(
      try core.validateEngineTranscript(Data(transcript.utf8))
    ) {
      XCTAssertEqual($0 as? EngineContractError, .stalePlanDigest(4))
    }
  }

  func testSignedCatalogAdmitsOnlyEnabledModel() throws {
    let fixture = try makeCatalog(sequence: 7)

    let result = try core.validateSupportCatalog(
      payload: fixture.payload,
      signature: fixture.signature,
      trustRoot: fixture.trustRoot,
      now: now
    )

    XCTAssertEqual(result.sequence, 7)
    guard case .admitted(let record) = result.admission(for: "apple,j314s") else {
      return XCTFail("Expected the signed M1 Pro record to be admitted")
    }
    XCTAssertEqual(record.asahiInstallerTag, "v0.9.0")
    XCTAssertEqual(
      result.admission(for: "apple,j614s"),
      .unsupported(deviceIdentifier: "apple,j614s")
    )
  }

  func testCatalogRejectsInvalidSignature() throws {
    let fixture = try makeCatalog(sequence: 8)
    let mutatedPayload = fixture.payload + Data(" ".utf8)

    XCTAssertThrowsError(
      try core.validateSupportCatalog(
        payload: mutatedPayload,
        signature: fixture.signature,
        trustRoot: fixture.trustRoot,
        now: now
      )
    ) {
      XCTAssertEqual($0 as? SupportCatalogError, .invalidSignature)
    }
  }

  func testSignedSchemaThreeCatalogBindsRepairManifestArtifact() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let issued = ISO8601DateFormatter().string(
      from: now.addingTimeInterval(-3_600)
    )
    let expires = ISO8601DateFormatter().string(
      from: now.addingTimeInterval(86_400)
    )
    let repairDigest = "sha256:" + String(repeating: "7", count: 64)
    let payload = Data(
      """
      {"schemaVersion":3,"sequence":13,"issuedAt":"\(issued)","expiresAt":"\(expires)","models":[{"deviceIdentifier":"apple,j314s","status":"enabled","operation":"repair-installed-system","asahiInstallerTag":"v0.9.0","asahiInstallerRevision":"\(String(repeating: "a", count: 40))","asahiInstallerDataRevision":"\(String(repeating: "b", count: 40))","downstreamRevision":"\(String(repeating: "c", count: 40))","engineVersion":"v0.9.0-omarchy.7","engineDigest":"sha256:\(String(repeating: "d", count: 64))","metadataDigest":"sha256:\(String(repeating: "e", count: 64))","payloadDigest":"sha256:\(String(repeating: "f", count: 64))","repairManifestDigest":"\(repairDigest)","evidenceRevision":"evidence-repair-1","engineArtifact":{"sourceURL":"https://downloads.example.com/engine.tar.gz","fileName":"engine.tar.gz","sizeBytes":1},"metadataArtifact":{"sourceURL":"https://downloads.example.com/metadata.json","fileName":"metadata.json","sizeBytes":1},"payloadArtifact":{"sourceURL":"https://downloads.example.com/payload.zip","fileName":"payload.zip","sizeBytes":1},"repairManifestArtifact":{"sourceURL":"https://downloads.example.com/repair.json","fileName":"repair.json","sizeBytes":1}}]}
      """.utf8
    )
    let publicKey = privateKey.publicKey.rawRepresentation
    let fingerprint =
      "sha256:"
      + SHA256.hash(data: publicKey)
      .map { String(format: "%02x", $0) }
      .joined()
    let catalog = try core.validateSupportCatalog(
      payload: payload,
      signature: try privateKey.signature(for: payload),
      trustRoot: try AppOwnedTrustRoot(
        rawRepresentation: publicKey,
        expectedFingerprint: fingerprint
      ),
      now: now
    )
    guard case .admitted(let record) = catalog.admission(for: "apple,j314s")
    else {
      return XCTFail("Expected repair catalog admission")
    }

    XCTAssertEqual(record.operation, "repair-installed-system")
    XCTAssertEqual(record.repairManifestDigest, repairDigest)
    XCTAssertEqual(record.delivery?.repairManifest?.role, "repair-manifest")
    XCTAssertEqual(
      record.delivery?.repairManifest?.expectedDigest,
      repairDigest
    )
  }

  // MARK: Schema 4 — no expiry

  func testSchemaFourCatalogWithoutExpiryStaysValidFarInTheFuture() throws {
    let fixture = try makeCatalog(
      sequence: 40,
      schemaVersion: 4,
      includeExpiry: false
    )

    let validated = try core.validateSupportCatalog(
      payload: fixture.payload,
      signature: fixture.signature,
      trustRoot: fixture.trustRoot,
      now: now.addingTimeInterval(10 * 365 * 86_400)
    )

    XCTAssertEqual(validated.sequence, 40)
  }

  func testSchemaFourCatalogWithoutExpiryInstallsWhenTheClockIsBehind() throws {
    let fixture = try makeCatalog(
      sequence: 41,
      schemaVersion: 4,
      includeExpiry: false
    )

    let validated = try core.validateSupportCatalog(
      payload: fixture.payload,
      signature: fixture.signature,
      trustRoot: fixture.trustRoot,
      now: now.addingTimeInterval(-10 * 365 * 86_400)
    )

    XCTAssertEqual(validated.sequence, 41)
  }

  func testSchemaFourCatalogWithAnExpiryStillEnforcesIt() throws {
    let fixture = try makeCatalog(
      sequence: 42,
      issuedAt: now.addingTimeInterval(-7_200),
      expiresAt: now.addingTimeInterval(-3_600),
      schemaVersion: 4
    )

    XCTAssertThrowsError(
      try core.validateSupportCatalog(
        payload: fixture.payload,
        signature: fixture.signature,
        trustRoot: fixture.trustRoot,
        now: now
      )
    ) {
      XCTAssertEqual($0 as? SupportCatalogError, .expired)
    }
  }

  func testLegacySchemaWithoutAnExpiryIsRejected() throws {
    let fixture = try makeCatalog(
      sequence: 43,
      schemaVersion: 2,
      includeExpiry: false
    )

    XCTAssertThrowsError(
      try core.validateSupportCatalog(
        payload: fixture.payload,
        signature: fixture.signature,
        trustRoot: fixture.trustRoot,
        now: now
      )
    ) {
      XCTAssertEqual($0 as? SupportCatalogError, .invalidField("expiresAt"))
    }
  }

  func testAnUnsupportedSchemaIsStillRejected() throws {
    let fixture = try makeCatalog(
      sequence: 44,
      schemaVersion: 5,
      includeExpiry: false
    )

    XCTAssertThrowsError(
      try core.validateSupportCatalog(
        payload: fixture.payload,
        signature: fixture.signature,
        trustRoot: fixture.trustRoot,
        now: now
      )
    ) {
      XCTAssertEqual($0 as? SupportCatalogError, .unsupportedSchema(5))
    }
  }

  // MARK: Installer compatibility block

  func testInstallerCompatibilityIsAbsentByDefault() throws {
    let fixture = try makeCatalog(sequence: 45)

    let validated = try core.validateSupportCatalog(
      payload: fixture.payload,
      signature: fixture.signature,
      trustRoot: fixture.trustRoot,
      now: now
    )

    XCTAssertNil(validated.installerCompatibility)
  }

  func testInstallerCompatibilityIsExposedWhenPresent() throws {
    let fixture = try makeCatalog(
      sequence: 46,
      schemaVersion: 4,
      includeExpiry: false,
      installer: installerBlock(minimum: "2.0.0", latest: "2.3.1")
    )

    let validated = try core.validateSupportCatalog(
      payload: fixture.payload,
      signature: fixture.signature,
      trustRoot: fixture.trustRoot,
      now: now
    )

    let compatibility = try XCTUnwrap(validated.installerCompatibility)
    XCTAssertEqual(compatibility.minimumVersion, InstallerVersion("2.0.0"))
    XCTAssertEqual(compatibility.latestVersion, InstallerVersion("2.3.1"))
    XCTAssertEqual(
      compatibility.downloadURL.absoluteString,
      "https://downloads.example.com/installer/stable/Installer.pkg"
    )
    XCTAssertTrue(compatibility.accepts(InstallerVersion("2.0.0")!))
    XCTAssertFalse(compatibility.accepts(InstallerVersion("1.9.9")!))
  }

  func testAMinimumNewerThanTheLatestIsRejected() throws {
    let fixture = try makeCatalog(
      sequence: 47,
      schemaVersion: 4,
      includeExpiry: false,
      installer: installerBlock(minimum: "3.0.0", latest: "2.0.0")
    )

    XCTAssertThrowsError(
      try core.validateSupportCatalog(
        payload: fixture.payload,
        signature: fixture.signature,
        trustRoot: fixture.trustRoot,
        now: now
      )
    ) {
      XCTAssertEqual(
        $0 as? SupportCatalogError,
        .invalidField("installer.minimumVersion")
      )
    }
  }

  func testAMalformedInstallerVersionIsRejected() throws {
    let fixture = try makeCatalog(
      sequence: 48,
      schemaVersion: 4,
      includeExpiry: false,
      installer: installerBlock(minimum: "2.0", latest: "2.0.0")
    )

    XCTAssertThrowsError(
      try core.validateSupportCatalog(
        payload: fixture.payload,
        signature: fixture.signature,
        trustRoot: fixture.trustRoot,
        now: now
      )
    ) {
      XCTAssertEqual(
        $0 as? SupportCatalogError,
        .invalidField("installer.minimumVersion")
      )
    }
  }

  func testAPlainHTTPInstallerDownloadURLIsRejected() throws {
    let fixture = try makeCatalog(
      sequence: 49,
      schemaVersion: 4,
      includeExpiry: false,
      installer: installerBlock(
        minimum: "2.0.0",
        latest: "2.0.0",
        downloadURL: "http://downloads.example.com/Installer.pkg"
      )
    )

    XCTAssertThrowsError(
      try core.validateSupportCatalog(
        payload: fixture.payload,
        signature: fixture.signature,
        trustRoot: fixture.trustRoot,
        now: now
      )
    ) {
      XCTAssertEqual(
        $0 as? SupportCatalogError,
        .invalidField("installer.downloadURL")
      )
    }
  }

  func testAnUnknownTopLevelFieldIsIgnored() throws {
    // The catalog is intentionally additive: an older verifier must keep
    // working when a newer publisher adds a field it does not know.
    let fixture = try makeCatalog(
      sequence: 50,
      schemaVersion: 4,
      includeExpiry: false,
      installer: installerBlock(minimum: "2.0.0", latest: "2.0.0")
    )
    var text = try XCTUnwrap(String(data: fixture.payload, encoding: .utf8))
    text = text.replacingOccurrences(
      of: "\"models\":",
      with: "\"somethingNewer\":{\"a\":1},\"models\":"
    )
    let payload = Data(text.utf8)
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation
    let fingerprint =
      "sha256:"
      + SHA256.hash(data: publicKey)
      .map { String(format: "%02x", $0) }
      .joined()

    let validated = try core.validateSupportCatalog(
      payload: payload,
      signature: try key.signature(for: payload),
      trustRoot: try AppOwnedTrustRoot(
        rawRepresentation: publicKey,
        expectedFingerprint: fingerprint
      ),
      now: now
    )

    XCTAssertEqual(validated.sequence, 50)
  }

  func testCatalogRejectsExpiredManifest() throws {
    let fixture = try makeCatalog(
      sequence: 9,
      issuedAt: now.addingTimeInterval(-7_200),
      expiresAt: now.addingTimeInterval(-3_600)
    )

    XCTAssertThrowsError(
      try core.validateSupportCatalog(
        payload: fixture.payload,
        signature: fixture.signature,
        trustRoot: fixture.trustRoot,
        now: now
      )
    ) {
      XCTAssertEqual($0 as? SupportCatalogError, .expired)
    }
  }

  func testOlderCatalogCannotRollBackAcceptedIdentity() throws {
    let current = try validateCatalog(makeCatalog(sequence: 10))
    let older = try makeCatalog(sequence: 9)

    XCTAssertThrowsError(
      try core.validateSupportCatalog(
        payload: older.payload,
        signature: older.signature,
        trustRoot: older.trustRoot,
        now: now,
        previouslyAccepted: current.acceptedIdentity
      )
    ) {
      XCTAssertEqual(
        $0 as? SupportCatalogSequenceError,
        .rollback(stored: 10, candidate: 9)
      )
    }
  }

  func testDifferentPayloadCannotReuseAcceptedSequence() throws {
    let first = try validateCatalog(
      makeCatalog(sequence: 11, evidence: "evidence-a")
    )
    let replacement = try makeCatalog(
      sequence: 11,
      evidence: "evidence-b"
    )

    XCTAssertThrowsError(
      try core.validateSupportCatalog(
        payload: replacement.payload,
        signature: replacement.signature,
        trustRoot: replacement.trustRoot,
        now: now,
        previouslyAccepted: first.acceptedIdentity
      )
    ) {
      XCTAssertEqual($0 as? SupportCatalogSequenceError, .sequenceReuse(11))
    }
  }

  func testExactCatalogReplayIsIdempotent() throws {
    let fixture = try makeCatalog(sequence: 12)
    let first = try validateCatalog(fixture)
    let replay = try core.validateSupportCatalog(
      payload: fixture.payload,
      signature: fixture.signature,
      trustRoot: fixture.trustRoot,
      now: now,
      previouslyAccepted: first.acceptedIdentity
    )

    XCTAssertEqual(replay.acceptedIdentity, first.acceptedIdentity)
  }

  func testAcceptedIdentityRejectsInvalidPersistedValues() {
    XCTAssertThrowsError(
      try AcceptedCatalogIdentity(
        sequence: 0,
        payloadDigest: "sha256:" + String(repeating: "a", count: 64)
      )
    ) {
      XCTAssertEqual(
        $0 as? SupportCatalogSequenceError,
        .invalidStoredIdentity
      )
    }
  }

  func testSignedCatalogBindsMultiPartPayloadArtifact() throws {
    let catalog = try validateSigned(
      payload: partsCatalogPayload(payloadParts: twoPartManifest)
    )

    guard case .admitted(let record) = catalog.admission(for: "apple,j314s")
    else {
      return XCTFail("Expected the multi-part payload record to be admitted")
    }
    let parts = try XCTUnwrap(record.delivery?.payload.parts)
    XCTAssertEqual(
      parts.map(\.fileName),
      ["payload.zip.part00", "payload.zip.part01"]
    )
    XCTAssertEqual(parts.map(\.expectedSizeBytes), [5, 7])
    XCTAssertEqual(
      parts.map(\.sourceURL.absoluteString),
      [
        "https://downloads.example.com/payload.zip.part00",
        "https://downloads.example.com/payload.zip.part01",
      ]
    )
    XCTAssertEqual(
      parts.first?.expectedDigest,
      "sha256:" + String(repeating: "1", count: 64)
    )
    XCTAssertEqual(record.delivery?.engine.parts, [])
  }

  func testCatalogRejectsPartsOutsidePayloadArtifact() {
    XCTAssertThrowsError(
      try validateSigned(
        payload: partsCatalogPayload(engineParts: twoPartManifest)
      )
    ) {
      XCTAssertEqual(
        $0 as? SupportCatalogError,
        .invalidField("models[0].engineArtifact.parts")
      )
    }
  }

  func testCatalogRejectsMalformedPayloadParts() {
    let single = """
      [{"sourceURL":"https://downloads.example.com/payload.zip.part00","fileName":"payload.zip.part00","sizeBytes":12,"sha256":"sha256:\(String(repeating: "1", count: 64))"}]
      """
    XCTAssertThrowsError(
      try validateSigned(payload: partsCatalogPayload(payloadParts: single))
    ) {
      XCTAssertEqual(
        $0 as? SupportCatalogError,
        .invalidField("models[0].payloadArtifact.parts")
      )
    }

    let mismatchedSum = """
      [{"sourceURL":"https://downloads.example.com/payload.zip.part00","fileName":"payload.zip.part00","sizeBytes":5,"sha256":"sha256:\(String(repeating: "1", count: 64))"},{"sourceURL":"https://downloads.example.com/payload.zip.part01","fileName":"payload.zip.part01","sizeBytes":8,"sha256":"sha256:\(String(repeating: "2", count: 64))"}]
      """
    XCTAssertThrowsError(
      try validateSigned(
        payload: partsCatalogPayload(payloadParts: mismatchedSum)
      )
    ) {
      XCTAssertEqual(
        $0 as? SupportCatalogError,
        .invalidField("models[0].artifacts")
      )
    }

    let insecurePart = """
      [{"sourceURL":"http://downloads.example.com/payload.zip.part00","fileName":"payload.zip.part00","sizeBytes":5,"sha256":"sha256:\(String(repeating: "1", count: 64))"},{"sourceURL":"https://downloads.example.com/payload.zip.part01","fileName":"payload.zip.part01","sizeBytes":7,"sha256":"sha256:\(String(repeating: "2", count: 64))"}]
      """
    XCTAssertThrowsError(
      try validateSigned(
        payload: partsCatalogPayload(payloadParts: insecurePart)
      )
    ) {
      XCTAssertEqual(
        $0 as? SupportCatalogError,
        .invalidField("models[0].artifacts")
      )
    }

    let duplicateName = """
      [{"sourceURL":"https://downloads.example.com/payload.zip.part00","fileName":"payload.zip.part00","sizeBytes":5,"sha256":"sha256:\(String(repeating: "1", count: 64))"},{"sourceURL":"https://downloads.example.com/payload.zip.part01","fileName":"payload.zip.part00","sizeBytes":7,"sha256":"sha256:\(String(repeating: "2", count: 64))"}]
      """
    XCTAssertThrowsError(
      try validateSigned(
        payload: partsCatalogPayload(payloadParts: duplicateName)
      )
    ) {
      XCTAssertEqual(
        $0 as? SupportCatalogError,
        .invalidField("models[0].artifacts")
      )
    }
  }

  private var twoPartManifest: String {
    """
    [{"sourceURL":"https://downloads.example.com/payload.zip.part00","fileName":"payload.zip.part00","sizeBytes":5,"sha256":"sha256:\(String(repeating: "1", count: 64))"},{"sourceURL":"https://downloads.example.com/payload.zip.part01","fileName":"payload.zip.part01","sizeBytes":7,"sha256":"sha256:\(String(repeating: "2", count: 64))"}]
    """
  }

  private func partsCatalogPayload(
    payloadParts: String? = nil,
    engineParts: String? = nil
  ) -> Data {
    let issued = ISO8601DateFormatter().string(
      from: now.addingTimeInterval(-3_600)
    )
    let expires = ISO8601DateFormatter().string(
      from: now.addingTimeInterval(86_400)
    )
    let engineField = engineParts.map { ",\"parts\":\($0)" } ?? ""
    let payloadField = payloadParts.map { ",\"parts\":\($0)" } ?? ""
    return Data(
      """
      {"schemaVersion":2,"sequence":21,"issuedAt":"\(issued)","expiresAt":"\(expires)","models":[{"deviceIdentifier":"apple,j314s","status":"enabled","asahiInstallerTag":"v0.9.0","asahiInstallerRevision":"\(String(repeating: "a", count: 40))","asahiInstallerDataRevision":"\(String(repeating: "b", count: 40))","downstreamRevision":"\(String(repeating: "c", count: 40))","engineVersion":"v0.9.0-omarchy.7","engineDigest":"sha256:\(String(repeating: "d", count: 64))","metadataDigest":"sha256:\(String(repeating: "e", count: 64))","payloadDigest":"sha256:\(String(repeating: "f", count: 64))","evidenceRevision":"evidence-parts-1","engineArtifact":{"sourceURL":"https://downloads.example.com/engine.tar.gz","fileName":"engine.tar.gz","sizeBytes":1\(engineField)},"metadataArtifact":{"sourceURL":"https://downloads.example.com/metadata.json","fileName":"metadata.json","sizeBytes":1},"payloadArtifact":{"sourceURL":"https://downloads.example.com/payload.zip","fileName":"payload.zip","sizeBytes":12\(payloadField)}}]}
      """.utf8
    )
  }

  private func validateSigned(payload: Data) throws -> ValidatedSupportCatalog {
    let privateKey = Curve25519.Signing.PrivateKey()
    let publicKey = privateKey.publicKey.rawRepresentation
    let fingerprint =
      "sha256:"
      + SHA256.hash(data: publicKey)
      .map { String(format: "%02x", $0) }
      .joined()
    return try core.validateSupportCatalog(
      payload: payload,
      signature: try privateKey.signature(for: payload),
      trustRoot: try AppOwnedTrustRoot(
        rawRepresentation: publicKey,
        expectedFingerprint: fingerprint
      ),
      now: now
    )
  }

  private func validateCatalog(
    _ fixture: CatalogFixture
  ) throws -> ValidatedSupportCatalog {
    try core.validateSupportCatalog(
      payload: fixture.payload,
      signature: fixture.signature,
      trustRoot: fixture.trustRoot,
      now: now
    )
  }

  private func makeCatalog(
    sequence: UInt64,
    evidence: String = "evidence-1",
    issuedAt: Date? = nil,
    expiresAt: Date? = nil,
    schemaVersion: Int = 1,
    includeExpiry: Bool = true,
    installer: String? = nil
  ) throws -> CatalogFixture {
    let privateKey = Curve25519.Signing.PrivateKey()
    let issued = ISO8601DateFormatter().string(
      from: issuedAt ?? now.addingTimeInterval(-3_600)
    )
    let expires = ISO8601DateFormatter().string(
      from: expiresAt ?? now.addingTimeInterval(86_400)
    )
    let models = [
      catalogModel(
        deviceIdentifier: "apple,j314s",
        status: "enabled",
        evidence: evidence,
        withDelivery: schemaVersion >= 2
      ),
      catalogModel(
        deviceIdentifier: "apple,j614s",
        status: "disabled",
        evidence: evidence,
        withDelivery: schemaVersion >= 2
      ),
    ].joined(separator: ",")
    let expiryField = includeExpiry ? ",\"expiresAt\":\"\(expires)\"" : ""
    let installerField = installer.map { ",\"installer\":\($0)" } ?? ""
    let payload = Data(
      """
      {"schemaVersion":\(schemaVersion),"sequence":\(sequence),"issuedAt":"\(issued)"\(expiryField)\(installerField),"models":[\(models)]}
      """.utf8
    )
    let publicKey = privateKey.publicKey.rawRepresentation
    let fingerprint =
      "sha256:"
      + SHA256.hash(data: publicKey)
      .map { String(format: "%02x", $0) }
      .joined()
    return CatalogFixture(
      payload: payload,
      signature: try privateKey.signature(for: payload),
      trustRoot: try AppOwnedTrustRoot(
        rawRepresentation: publicKey,
        expectedFingerprint: fingerprint
      )
    )
  }

  private func installerBlock(
    minimum: String,
    latest: String,
    downloadURL: String = "https://downloads.example.com/installer/stable/Installer.pkg"
  ) -> String {
    """
    {"minimumVersion":"\(minimum)","latestVersion":"\(latest)","downloadURL":"\(downloadURL)"}
    """
  }

  private func catalogModel(
    deviceIdentifier: String,
    status: String,
    evidence: String,
    withDelivery: Bool = false
  ) -> String {
    let delivery =
      withDelivery
      ? #","engineVersion":"v0.9.0-omarchy.14","engineArtifact":{"sourceURL":"https://downloads.example.com/engine.tar.gz","fileName":"engine.tar.gz","sizeBytes":1},"metadataArtifact":{"sourceURL":"https://downloads.example.com/metadata.json","fileName":"metadata.json","sizeBytes":1},"payloadArtifact":{"sourceURL":"https://downloads.example.com/payload.zip","fileName":"payload.zip","sizeBytes":1}"#
      : ""
    return """
      {"deviceIdentifier":"\(deviceIdentifier)","status":"\(status)","asahiInstallerTag":"v0.9.0","asahiInstallerRevision":"\(String(repeating: "a", count: 40))","asahiInstallerDataRevision":"\(String(repeating: "b", count: 40))","downstreamRevision":"\(String(repeating: "c", count: 40))","engineDigest":"sha256:\(String(repeating: "d", count: 64))","metadataDigest":"sha256:\(String(repeating: "e", count: 64))","payloadDigest":"sha256:\(String(repeating: "f", count: 64))","evidenceRevision":"\(evidence)"\(delivery)}
      """
  }

  private func makeTranscript(
    eventPlanDigest: String? = nil,
    minimumInstallBytes: UInt64 = 67_501_226_240,
    trailingCheckpointPhase: String? = nil
  ) -> String {
    let layoutDigest = lengthPrefixedDigest(
      [
        "disk0", "free", "disk0s3", "447750000000", "107374182400",
      ],
      prefix: "sha256:"
    )
    let requiredHumanSteps = [
      "enterOneTrueRecovery",
      "authenticateMachineOwner",
    ]
    let planDigest = lengthPrefixedDigest(
      [
        "apple,j314s", "disk0", layoutDigest, "free", "disk0s3",
        "447750000000", "107374182400", "v0.9.0-omarchy.1",
        "sha256:" + String(repeating: "d", count: 64),
        "sha256:" + String(repeating: "e", count: 64),
        "sha256:" + String(repeating: "f", count: 64),
        requiredHumanSteps.joined(separator: ","),
      ],
      prefix: ""
    )
    let eventDigest = eventPlanDigest ?? planDigest
    let evidenceDigest = "sha256:" + String(repeating: "b", count: 64)

    var lines = [
      #"{"schema_version":1,"sequence":1,"type":"inspection","payload":{"device_identifier":"apple,j314s","support":"supported"}}"#,
      #"{"schema_version":1,"sequence":2,"type":"inventory","payload":{"layout_digest":"\#(layoutDigest)","system_store_identifier":"disk0","candidates":[{"kind":"free","source_identifier":"disk0s3","offset_bytes":447750000000,"length_bytes":107374182400,"minimum_install_bytes":\#(minimumInstallBytes),"minimum_container_bytes":0}]}}"#,
      #"{"schema_version":1,"sequence":3,"type":"plan","payload":{"plan_digest":"\#(planDigest)","device_identifier":"apple,j314s","store_identifier":"disk0","layout_digest":"\#(layoutDigest)","candidate_kind":"free","source_identifier":"disk0s3","offset_bytes":447750000000,"length_bytes":107374182400,"engine_version":"v0.9.0-omarchy.1","engine_digest":"sha256:\#(String(repeating: "d", count: 64))","metadata_digest":"sha256:\#(String(repeating: "e", count: 64))","payload_digest":"sha256:\#(String(repeating: "f", count: 64))","required_human_steps":["enterOneTrueRecovery","authenticateMachineOwner"]}}"#,
      #"{"schema_version":1,"sequence":4,"type":"event","payload":{"plan_digest":"\#(eventDigest)","name":"apfs_preparation_started"}}"#,
      #"{"schema_version":1,"sequence":5,"type":"checkpoint","payload":{"plan_digest":"\#(planDigest)","identifier":"cp-1","phase":"apfs_preparation","evidence_digest":"\#(evidenceDigest)"}}"#,
    ]
    if let trailingCheckpointPhase {
      lines.append(
        #"{"schema_version":1,"sequence":6,"type":"checkpoint","payload":{"plan_digest":"\#(planDigest)","identifier":"cp-late","phase":"\#(trailingCheckpointPhase)","evidence_digest":"\#(evidenceDigest)"}}"#
      )
    }
    lines.append(
      #"{"schema_version":1,"sequence":\#(lines.count + 1),"type":"completion","payload":{"plan_digest":"\#(planDigest)","outcome":"awaiting_recovery"}}"#
    )
    return lines.joined(separator: "\n") + "\n"
  }

  private func makeReplaceTranscript(
    planLengthBytes: UInt64 = 137_438_953_472,
    repairManifestDigest: String? = nil,
    minimumInstallBytes: UInt64 = 70_866_960_384,
    includeIdentityDigest: Bool = true,
    stageOneLines: Bool = false
  ) -> String {
    let identityDigest = "sha256:" + String(repeating: "9", count: 64)
    var layoutFields = [
      "disk0", "replace", "disk0s3", "857747943424", "137438953472",
    ]
    if includeIdentityDigest {
      layoutFields.append(identityDigest)
    }
    let layoutDigest = lengthPrefixedDigest(layoutFields, prefix: "sha256:")
    let requiredHumanSteps = [
      "enterOneTrueRecovery",
      "authenticateMachineOwner",
    ]
    var planFields = [
      "apple,j314s", "disk0", layoutDigest, "replace", "disk0s3",
      "857747943424", String(planLengthBytes), "v0.9.0-omarchy.7",
      "sha256:" + String(repeating: "d", count: 64),
      "sha256:" + String(repeating: "e", count: 64),
      "sha256:" + String(repeating: "f", count: 64),
    ]
    if let repairManifestDigest {
      planFields.append(repairManifestDigest)
    }
    planFields.append(requiredHumanSteps.joined(separator: ","))
    let planDigest = lengthPrefixedDigest(planFields, prefix: "")
    let identityField =
      includeIdentityDigest
      ? #","identity_digest":"\#(identityDigest)""#
      : ""
    let repairField =
      repairManifestDigest.map {
        #","repair_manifest_digest":"\#($0)""#
      } ?? ""
    let evidenceDigest = "sha256:" + String(repeating: "b", count: 64)

    var lines = [
      #"{"schema_version":1,"sequence":1,"type":"inspection","payload":{"device_identifier":"apple,j314s","support":"supported"}}"#,
      #"{"schema_version":1,"sequence":2,"type":"inventory","payload":{"layout_digest":"\#(layoutDigest)","system_store_identifier":"disk0","candidates":[{"kind":"replace","source_identifier":"disk0s3","offset_bytes":857747943424,"length_bytes":137438953472,"minimum_install_bytes":\#(minimumInstallBytes),"minimum_container_bytes":0\#(identityField)}]}}"#,
      #"{"schema_version":1,"sequence":3,"type":"plan","payload":{"plan_digest":"\#(planDigest)","device_identifier":"apple,j314s","store_identifier":"disk0","layout_digest":"\#(layoutDigest)","candidate_kind":"replace","source_identifier":"disk0s3","offset_bytes":857747943424,"length_bytes":\#(planLengthBytes),"engine_version":"v0.9.0-omarchy.7","engine_digest":"sha256:\#(String(repeating: "d", count: 64))","metadata_digest":"sha256:\#(String(repeating: "e", count: 64))","payload_digest":"sha256:\#(String(repeating: "f", count: 64))"\#(repairField),"required_human_steps":["enterOneTrueRecovery","authenticateMachineOwner"]}}"#,
    ]
    if stageOneLines {
      let stages = [
        ("existing_removal_started", "existing-install-removed", "existing_removal"),
        ("apfs_preparation_started", "apfs-target-prepared", "apfs_preparation"),
        ("stub_and_esp_started", "stub-and-esp-installed", "stub_and_esp"),
        ("recovery_handoff_started", "recovery-handoff-prepared", "awaiting_recovery"),
      ]
      for (event, identifier, phase) in stages {
        lines.append(
          #"{"schema_version":1,"sequence":\#(lines.count + 1),"type":"event","payload":{"plan_digest":"\#(planDigest)","name":"\#(event)"}}"#
        )
        lines.append(
          #"{"schema_version":1,"sequence":\#(lines.count + 1),"type":"checkpoint","payload":{"plan_digest":"\#(planDigest)","identifier":"\#(identifier)","phase":"\#(phase)","evidence_digest":"\#(evidenceDigest)"}}"#
        )
      }
      lines.append(
        #"{"schema_version":1,"sequence":\#(lines.count + 1),"type":"completion","payload":{"plan_digest":"\#(planDigest)","outcome":"awaiting_recovery"}}"#
      )
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private func lengthPrefixedDigest(
    _ fields: [String],
    prefix: String
  ) -> String {
    let canonical =
      fields
      .map { "\($0.utf8.count):\($0)" }
      .joined(separator: "|")
    let digest = SHA256.hash(data: Data(canonical.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return prefix + digest
  }
}

private struct CatalogFixture {
  let payload: Data
  let signature: Data
  let trustRoot: AppOwnedTrustRoot
}
