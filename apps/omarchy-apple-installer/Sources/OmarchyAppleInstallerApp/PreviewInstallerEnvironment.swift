#if DEBUG
  import Foundation
  import OmarchyAppleInstallerTrustCore
  import OmarchyInstallerUXCore

  /// Debug-only environment that replays a recorded execution journal through
  /// the real trust-core decoder so every screen can be reviewed on a machine
  /// that is not installable — including this blocked M4.
  ///
  /// Nothing here is compiled into a release build, no fixture is bundled into
  /// app resources, and no trust type with a non-public initializer is
  /// fabricated: the display-model seam makes that unnecessary.
  final class PreviewInstallerEnvironment: InstallerEnvironment, @unchecked Sendable {
    private let scenario: InstallerPreviewScenario
    private let journalURL: URL?
    private let lock = NSLock()
    private var approved = false
    private var credentialAttempts = 0

    init(scenario: InstallerPreviewScenario, journalURL: URL?) {
      self.scenario = scenario
      self.journalURL = journalURL
    }

    var isSimulation: Bool { true }

    var installationBlocked: Bool { scenario == .unsupported }
    var engineSupported: Bool { scenario != .unsupported }

    var hasApprovedPlan: Bool {
      lock.withLock { approved }
    }

    var helperStatus: HelperDisplay {
      HelperDisplay(status: .enabled)
    }

    func refreshHelperStatus() -> HelperDisplay { helperStatus }

    func inspect() async throws -> HostDisplay {
      try? await Task.sleep(for: .milliseconds(700))
      let transcript = try loadValidatedTranscript()
      let blocked = scenario == .unsupported
      let device = blocked ? "apple,j614s" : transcript.deviceIdentifier
      let free: UInt64 = 464_000_000_000

      return HostDisplay(
        chipAndSpace: blocked
          ? "Apple M4 · \(device)"
          : "Apple M1 Pro · \(PlainLanguage.bytes(free)) free",
        supported: !blocked,
        existingInstalls: scenario == .existingInstall
          ? [ExistingInstallDisplay(sourceIdentifier: "disk0s3", sizeDescription: "128 GB")]
          : []
      )
    }

    func preparePlan(
      omarchyBytes: UInt64?,
      progress: @escaping @Sendable (AssetProgressUpdate) -> Void
    ) async throws -> PlanPreparationDisplay {
      if scenario == .existingInstall {
        try? await Task.sleep(for: .milliseconds(400))
        return .existingInstallChoice([
          ExistingInstallDisplay(
            sourceIdentifier: "disk0s3",
            sizeDescription: PlainLanguage.bytes(137_438_953_472)
          )
        ])
      }

      let transcript = try loadValidatedTranscript()
      guard let plan = transcript.plan else {
        throw InstallerAppError.inspectionRequired
      }

      let artifacts = Self.previewArtifacts
      if omarchyBytes != nil {
        // A size change re-plans against already verified files.
        try? await Task.sleep(for: .milliseconds(250))
        let total: UInt64 = 994_662_584_320
        let unit: UInt64 = 1_000_000_000
        let length = min(total - 120 * unit, max(30 * unit, omarchyBytes ?? plan.lengthBytes))
        return .plan(Self.planDisplay(length: length, total: total))
      }

      progress(AssetProgressUpdate(stage: .fetchingCatalog))
      try? await Task.sleep(for: .milliseconds(500))

      for step in 1...12 {
        let fraction = Double(step) / 12
        let rows = artifacts.map { artifact in
          AssetProgressRow(
            role: artifact.role,
            fileName: artifact.fileName,
            bytesCompleted: UInt64(Double(artifact.expectedBytes) * fraction),
            totalBytes: artifact.expectedBytes,
            phase: step == 12 ? .verified : .downloading
          )
        }
        progress(AssetProgressUpdate(stage: .downloading, rows: rows))
        try? await Task.sleep(for: .milliseconds(140))
      }

      progress(AssetProgressUpdate(stage: .inspectingEngine))
      try? await Task.sleep(for: .milliseconds(500))
      progress(AssetProgressUpdate(stage: .planning))
      try? await Task.sleep(for: .milliseconds(400))

      let total: UInt64 = 994_662_584_320
      let unit: UInt64 = 1_000_000_000
      let length = min(total - 120 * unit, max(30 * unit, omarchyBytes ?? plan.lengthBytes))
      return .plan(Self.planDisplay(length: length, total: total))
    }

    private static func planDisplay(length: UInt64, total: UInt64) -> PlanDisplay {
      PlanDisplay(
        diskTotalBytes: total,
        omarchyBytes: length,
        bindingDigest: "sha256:" + String(repeating: "b", count: 64),
        minimumBytes: 30_000_000_000, maximumBytes: total - 120_000_000_000,
        releaseDescription: "Recorded preview"
      )
    }

    func approve() throws {
      lock.withLock { approved = true }
    }

    func discardApproval() {
      lock.withLock { approved = false }
    }

    func execute(
      operation: InstallOperationKind,
      authorization: MachineOwnerAuthorization,
      journal: @escaping @Sendable (Data) -> Void
    ) async throws -> CompletionDisplay {
      if scenario == .credentialReject {
        let first = lock.withLock { () -> Bool in
          credentialAttempts += 1
          return credentialAttempts == 1
        }
        if first, operation == .install {
          try? await Task.sleep(for: .milliseconds(1400))
          throw EngineXPCSubmissionError.machineOwnerCredentialsRejected
        }
      }

      let lines = try loadJournalLines()
      var forwarded = Data()
      for (index, line) in lines.enumerated() {
        try? await Task.sleep(for: .milliseconds(800))
        if scenario == .degradedJournal, index == 5 {
          journal(Data("{\"broken\":true}\n".utf8))
          continue
        }
        forwarded.append(line)
        journal(line)

        if scenario == .recoveryRetry,
          operation == .install,
          index == 6
        {
          throw EngineXPCSubmissionError.recoveryAuthorizationFailed
        }
      }

      let transcript = try AppleInstallerTrustCore()
        .validateEngineTranscript(
          lines.reduce(into: Data()) { $0.append($1) }
        )
      let steps = transcript.plan?.requiredHumanSteps ?? []
      return CompletionDisplay(
        nextAction: .enterRecovery,
        headline: PlainLanguage.recoveryHeadline,
        subheadline: PlainLanguage.nextActionMessage(.enterRecovery),
        verified: PlainLanguage.doneVerifiedRows,
        handoff: HandoffDisplay(
          headline: PlainLanguage.recoveryHeadline,
          steps: PlainLanguage.recoverySteps(for: steps)
        )
      )
    }

    // MARK: Fixture

    /// The files the download bar counts through, sized like a real release.
    private struct PreviewArtifact {
      let role: String
      let fileName: String
      let expectedBytes: UInt64
    }

    private static let previewArtifacts = [
      PreviewArtifact(
        role: "payload",
        fileName: "omarchy-2026.09.02-aarch64-apple-silicon-asahi-os-package.zip",
        expectedBytes: 3_638_729_568
      ),
      PreviewArtifact(
        role: "metadata",
        fileName: "installer_data.json",
        expectedBytes: 34_000_000
      ),
      PreviewArtifact(
        role: "engine",
        fileName: "installer-v0.9.0-omarchy.14.tar.gz",
        expectedBytes: 22_000_000
      ),
    ]

    private func loadJournalLines() throws -> [Data] {
      guard let journalURL else {
        throw InstallerAppError.previewFixtureUnavailable
      }
      let data = try Data(contentsOf: journalURL)
      // Each forwarded chunk must end in a newline, or the live model treats
      // the stream as degraded.
      let lines = LiveInstallJournalModel.lines(in: data).map { $0 + [0x0A] }
      guard !lines.isEmpty else {
        throw InstallerAppError.previewFixtureUnavailable
      }
      return lines
    }

    private func loadValidatedTranscript() throws -> ValidatedEngineTranscript {
      let lines = try loadJournalLines()
      return try AppleInstallerTrustCore()
        .validateEngineTranscript(
          lines.reduce(into: Data()) { $0.append($1) }
        )
    }
  }
#endif
