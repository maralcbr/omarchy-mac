#if os(macOS)
  import CryptoKit
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class InstallerPlanReviewTests: XCTestCase {
    func testExactOwnerConfirmationProducesCandidateBoundApproval() throws {
      let fixture = try makeFixture()
      let review = try InstallerPlanReviewCoordinator().prepare(
        fixture.request
      )

      let approval = try review.approve(
        confirming: confirmation(for: review)
      )

      XCTAssertEqual(approval.identity, review.identity)
      XCTAssertEqual(
        approval.approvedBindingDigest,
        review.identity.bindingDigest
      )
    }

    func testChangedExtentCannotReuseOwnerConfirmation() throws {
      let fixture = try makeFixture()
      let review = try InstallerPlanReviewCoordinator().prepare(
        fixture.request
      )
      let changed = InstallerOwnerPlanConfirmation(
        bindingDigest: review.identity.bindingDigest,
        planDigest: review.plan.planDigest,
        deviceIdentifier: review.plan.deviceIdentifier,
        storeIdentifier: review.plan.storeIdentifier,
        sourceIdentifier: review.plan.sourceIdentifier,
        offsetBytes: review.plan.offsetBytes,
        lengthBytes: review.plan.lengthBytes - 1_048_576,
        requiredHumanSteps: review.plan.requiredHumanSteps
      )

      XCTAssertThrowsError(try review.approve(confirming: changed)) {
        XCTAssertEqual(
          $0 as? InstallerPlanReviewError,
          .ownerConfirmationMismatch
        )
      }
    }

    func testPlanningTranscriptMustMatchInspectedMac() throws {
      let fixture = try makeFixture(hostDeviceIdentifier: "apple,j293")

      XCTAssertThrowsError(
        try InstallerPlanReviewCoordinator().prepare(fixture.request)
      ) {
        XCTAssertEqual(
          $0 as? InstallerPlanReviewError,
          .deviceMismatch(
            expected: "apple,j293",
            actual: "apple,j314s"
          )
        )
      }
    }

    func testStagedAssetsMustMatchCandidateBoundPlan() throws {
      let fixture = try makeFixture(alterEngineArtifact: true)

      XCTAssertThrowsError(
        try InstallerPlanReviewCoordinator().prepare(fixture.request)
      ) {
        XCTAssertEqual(
          $0 as? InstallerPlanReviewError,
          .assetBindingMismatch
        )
      }
    }

    func testAwaitingRecoveryMapsToExplicitOwnerNextAction() throws {
      let fixture = try makeFixture()
      let review = try InstallerPlanReviewCoordinator().prepare(
        fixture.request
      )
      let transcript = try AppleInstallerTrustCore()
        .validateEngineTranscript(fixture.transcript)

      let progress = try InstallerExecutionProgress(
        review: review,
        transcript: transcript
      )

      XCTAssertEqual(progress.nextAction, .enterRecovery)
      XCTAssertEqual(progress.completion, .awaitingRecovery)
      XCTAssertEqual(
        progress.requiredHumanSteps,
        ["enterOneTrueRecovery", "authenticateMachineOwner"]
      )
    }

    func testPreparationUsesExactInventoryCandidateAndPinnedIdentity()
      async throws
    {
      let fixture = try makeFixture()
      let inspection = try AppleInstallerTrustCore()
        .validateEngineTranscript(fixture.transcript)
      let candidate = try XCTUnwrap(inspection.inventory?.candidates.first)
      let planner = RecordingPlanExecutor(transcript: fixture.transcript)
      let base = fixture.request

      let prepared = try await InstallerPlanPreparationCoordinator(
        planner: planner
      ).prepareExecution(
        InstallerPlanPreparationRequest(
          host: base.host,
          release: base.release,
          configuration: base.configuration,
          inspectionTranscript: fixture.transcript,
          candidate: candidate,
          requestedLengthBytes: candidate.lengthBytes,
          validationTime: base.validationTime,
          scratchDirectory: URL(fileURLWithPath: "/private/tmp")
        )
      )
      let review = prepared.review

      let capturedRequest = await planner.capturedRequest()
      let capturedIdentity = await planner.capturedIdentity()
      XCTAssertEqual(capturedRequest?.candidateKind, candidate.kind)
      XCTAssertEqual(
        capturedRequest?.sourceIdentifier,
        candidate.sourceIdentifier
      )
      XCTAssertEqual(
        capturedRequest?.requestedLengthBytes,
        candidate.lengthBytes
      )
      XCTAssertEqual(
        capturedIdentity?.engineVersion,
        "v0.9.0-omarchy.2"
      )
      XCTAssertEqual(review.plan.lengthBytes, candidate.lengthBytes)
      XCTAssertEqual(
        prepared.candidateRequest.planningTranscript,
        fixture.transcript
      )

      let approval = try review.approve(
        confirming: confirmation(for: review)
      )
      let process = RecordingEngineProcess(response: fixture.transcript)
      let progress = try await InstallerExecutionCoordinator().execute(
        prepared,
        approval: approval,
        process: process
      )

      XCTAssertEqual(progress.nextAction, .enterRecovery)
      let capturedInvocation = await process.capturedInvocation()
      XCTAssertEqual(
        capturedInvocation?.candidateIdentity,
        review.identity
      )
    }

    private func confirmation(
      for review: InstallerPlanReview
    ) -> InstallerOwnerPlanConfirmation {
      InstallerOwnerPlanConfirmation(
        bindingDigest: review.identity.bindingDigest,
        planDigest: review.plan.planDigest,
        deviceIdentifier: review.plan.deviceIdentifier,
        storeIdentifier: review.plan.storeIdentifier,
        sourceIdentifier: review.plan.sourceIdentifier,
        offsetBytes: review.plan.offsetBytes,
        lengthBytes: review.plan.lengthBytes,
        requiredHumanSteps: review.plan.requiredHumanSteps
      )
    }

    private func makeFixture(
      hostDeviceIdentifier: String = "apple,j314s",
      alterEngineArtifact: Bool = false
    ) throws -> PlanReviewFixture {
      let privateKey = Curve25519.Signing.PrivateKey()
      let publicKey = privateKey.publicKey.rawRepresentation
      let trustRoot = try AppOwnedTrustRoot(
        rawRepresentation: publicKey,
        expectedFingerprint: digest(publicKey)
      )
      let catalog = catalogPayload()
      let signature = try privateKey.signature(for: catalog)
      let accepted = try AppleInstallerTrustCore().validateSupportCatalog(
        payload: catalog,
        signature: signature,
        trustRoot: trustRoot,
        now: validationTime
      )
      guard
        case .admitted(let installer) = accepted.admission(
          for: "apple,j314s"
        ), let delivery = installer.delivery
      else {
        XCTFail("Expected admitted schema-v2 installer")
        throw InstallerPlanReviewError.assetBindingMismatch
      }

      let alteredEngine = try PinnedInstallerArtifact(
        role: delivery.engine.role,
        sourceURL: delivery.engine.sourceURL,
        fileName: delivery.engine.fileName,
        expectedDigest: alterEngineArtifact
          ? "sha256:" + String(repeating: "0", count: 64)
          : delivery.engine.expectedDigest,
        expectedSizeBytes: delivery.engine.expectedSizeBytes
      )
      let assets = PreparedInstallerAssets(
        catalogIdentity: accepted.acceptedIdentity,
        installer: installer,
        engine: StagedInstallerArtifact(
          artifact: alteredEngine,
          fileURL: URL(fileURLWithPath: "/private/tmp/engine.tar.gz"),
          reusedExistingFile: false
        ),
        metadata: StagedInstallerArtifact(
          artifact: delivery.metadata,
          fileURL: URL(fileURLWithPath: "/private/tmp/metadata.json"),
          reusedExistingFile: false
        ),
        payload: StagedInstallerArtifact(
          artifact: delivery.payload,
          fileURL: URL(fileURLWithPath: "/private/tmp/payload.img.zst"),
          reusedExistingFile: false
        )
      )
      let documents = InstallerReleaseCatalogDocuments(
        payload: catalog,
        signature: signature
      )
      let release = PreparedInstallerRelease(
        assets: assets,
        catalogDocuments: documents
      )
      let configuration = InstallerReleaseConfiguration(
        channels: ReleaseChannelEndpoints(
          stable: URL(
            string: "https://releases.example.com/channels/stable/catalog.signed.json"
          )!,
          rc: URL(
            string: "https://releases.example.com/channels/rc/catalog.signed.json"
          )!
        ),
        defaultChannel: .stable,
        trustRoot: trustRoot,
        helperMachServiceName: "com.omarchy.apple-installer.helper",
        helperCodeSigningRequirement:
          #"identifier "com.omarchy.apple-installer.helper""#
      )
      let transcript = planningTranscript()
      let host = AppleSiliconHostInspection(
        identity: AppleMacIdentity(
          model: "MacBookPro18,3",
          chip: "Apple M1 Pro",
          deviceIdentifier: hostDeviceIdentifier
        ),
        eligibility: .requiresSignedCatalog,
        macOSVersion: "Version 15.6",
        powerSource: .ac,
        fileVaultEnabled: true,
        storage: APFSStorageInspection(
          containerIdentifier: "disk3",
          physicalStoreIdentifier: "disk0s2",
          isInternal: true,
          containerSizeBytes: 1_000,
          containerFreeBytes: 500,
          minimumPreferredSizeBytes: 600
        )
      )

      return PlanReviewFixture(
        request: InstallerPlanReviewRequest(
          host: host,
          release: release,
          configuration: configuration,
          planningTranscript: transcript,
          validationTime: validationTime
        ),
        transcript: transcript
      )
    }

    private var validationTime: Date {
      Date(timeIntervalSince1970: 1_788_000_000)
    }

    private func catalogPayload() -> Data {
      let issued = ISO8601DateFormatter().string(
        from: validationTime.addingTimeInterval(-3_600)
      )
      let expires = ISO8601DateFormatter().string(
        from: validationTime.addingTimeInterval(86_400)
      )
      return Data(
        """
        {"schemaVersion":2,"sequence":50,"issuedAt":"\(issued)","expiresAt":"\(expires)","models":[{"deviceIdentifier":"apple,j314s","status":"enabled","asahiInstallerTag":"v0.9.0","asahiInstallerRevision":"\(String(repeating: "a", count: 40))","asahiInstallerDataRevision":"\(String(repeating: "b", count: 40))","downstreamRevision":"\(String(repeating: "c", count: 40))","engineVersion":"v0.9.0-omarchy.2","engineDigest":"sha256:\(String(repeating: "d", count: 64))","metadataDigest":"sha256:\(String(repeating: "e", count: 64))","payloadDigest":"sha256:\(String(repeating: "f", count: 64))","evidenceRevision":"evidence-s5","engineArtifact":{"sourceURL":"https://downloads.example.com/engine.tar.gz","fileName":"engine.tar.gz","sizeBytes":1},"metadataArtifact":{"sourceURL":"https://downloads.example.com/metadata.json","fileName":"metadata.json","sizeBytes":1},"payloadArtifact":{"sourceURL":"https://downloads.example.com/payload.img.zst","fileName":"payload.img.zst","sizeBytes":1}}]}
        """.utf8
      )
    }

    private func planningTranscript() -> Data {
      let lengthBytes: UInt64 = 107_374_182_400
      let layoutDigest = lengthPrefixedDigest(
        [
          "disk0", "free", "disk0s3", "447750000000",
          String(lengthBytes),
        ],
        prefix: "sha256:"
      )
      let humanSteps = [
        "enterOneTrueRecovery",
        "authenticateMachineOwner",
      ]
      let planDigest = lengthPrefixedDigest(
        [
          "apple,j314s", "disk0", layoutDigest, "free", "disk0s3",
          "447750000000", String(lengthBytes), "v0.9.0-omarchy.2",
          "sha256:" + String(repeating: "d", count: 64),
          "sha256:" + String(repeating: "e", count: 64),
          "sha256:" + String(repeating: "f", count: 64),
          humanSteps.joined(separator: ","),
        ],
        prefix: ""
      )
      let evidence = "sha256:" + String(repeating: "b", count: 64)
      let records = [
        #"{"schema_version":1,"sequence":1,"type":"inspection","payload":{"device_identifier":"apple,j314s","support":"supported"}}"#,
        #"{"schema_version":1,"sequence":2,"type":"inventory","payload":{"layout_digest":"\#(layoutDigest)","system_store_identifier":"disk0","candidates":[{"kind":"free","source_identifier":"disk0s3","offset_bytes":447750000000,"length_bytes":\#(lengthBytes),"minimum_install_bytes":67501226240,"minimum_container_bytes":0}]}}"#,
        #"{"schema_version":1,"sequence":3,"type":"plan","payload":{"plan_digest":"\#(planDigest)","device_identifier":"apple,j314s","store_identifier":"disk0","layout_digest":"\#(layoutDigest)","candidate_kind":"free","source_identifier":"disk0s3","offset_bytes":447750000000,"length_bytes":\#(lengthBytes),"engine_version":"v0.9.0-omarchy.2","engine_digest":"sha256:\#(String(repeating: "d", count: 64))","metadata_digest":"sha256:\#(String(repeating: "e", count: 64))","payload_digest":"sha256:\#(String(repeating: "f", count: 64))","required_human_steps":["enterOneTrueRecovery","authenticateMachineOwner"]}}"#,
        #"{"schema_version":1,"sequence":4,"type":"checkpoint","payload":{"plan_digest":"\#(planDigest)","identifier":"cp-1","phase":"apfs_preparation","evidence_digest":"\#(evidence)"}}"#,
        #"{"schema_version":1,"sequence":5,"type":"completion","payload":{"plan_digest":"\#(planDigest)","outcome":"awaiting_recovery"}}"#,
      ]
      return Data((records.joined(separator: "\n") + "\n").utf8)
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

    private func digest(_ data: Data) -> String {
      "sha256:"
        + SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
    }
  }

  private struct PlanReviewFixture {
    let request: InstallerPlanReviewRequest
    let transcript: Data
  }

  private actor RecordingPlanExecutor: InstallerPlanExecuting {
    private let transcript: Data
    private var request: PinnedAsahiPlanRequest?
    private var identity: PinnedAsahiPlanIdentity?

    init(transcript: Data) {
      self.transcript = transcript
    }

    func plan(
      _ archive: PinnedAsahiEngineArchive,
      request: PinnedAsahiPlanRequest,
      identity: PinnedAsahiPlanIdentity,
      repairManifestURL: URL?,
      in scratchDirectory: URL
    ) async throws -> Data {
      self.request = request
      self.identity = identity
      return transcript
    }

    func capturedRequest() -> PinnedAsahiPlanRequest? {
      request
    }

    func capturedIdentity() -> PinnedAsahiPlanIdentity? {
      identity
    }
  }

  private actor RecordingEngineProcess: EngineProcessExecuting {
    private let response: Data
    private var invocation: ClosedEngineInvocation?

    init(response: Data) {
      self.response = response
    }

    func execute(_ invocation: ClosedEngineInvocation) async throws -> Data {
      self.invocation = invocation
      return response
    }

    func capturedInvocation() -> ClosedEngineInvocation? {
      invocation
    }
  }
#endif
