#if DEBUG && os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore

  public enum InstallerSimulationScenario: String, CaseIterable, Identifiable, Sendable {
    case success, freeSpace, unsupported, engineUnavailable, existingInstall, missingHelper
    case downloadFailure, invalidDownload, outdatedInstaller, emptyChannel, planFailure
    case allocationClamped, allocationAligned, approvalChanged, credentialsRejected, connectionLost
    case emptyReply, helperFailure, degradedProgress, recoveryRetry, manualRecovery
    case shutdownFailure, completed, installationMedia

    public var id: String { rawValue }
    public var title: String {
      switch self {
      case .success: "Successful installation → Recovery"
      case .freeSpace: "Free space available · retain macOS"
      case .unsupported: "Unsupported Mac"
      case .engineUnavailable: "Engine unavailable"
      case .existingInstall: "Existing installation"
      case .missingHelper: "Installation service missing"
      case .downloadFailure: "Download interrupted"
      case .invalidDownload: "Download verification failed"
      case .outdatedInstaller: "Outdated installer"
      case .emptyChannel: "Empty release channel"
      case .planFailure: "Not enough usable space"
      case .allocationClamped: "Disk size adjusted during review"
      case .allocationAligned: "Disk alignment · whole GB unchanged"
      case .approvalChanged: "Plan changes before approval"
      case .credentialsRejected: "Credentials rejected on first attempt"
      case .connectionLost: "Connection lost after a disk change"
      case .emptyReply: "Installation result missing"
      case .helperFailure: "Installation service fails after a disk change"
      case .degradedProgress: "Live progress interrupted"
      case .recoveryRetry: "Recovery fails, then retry succeeds"
      case .manualRecovery: "Manual recovery required"
      case .shutdownFailure: "Shutdown request fails"
      case .completed: "Installation complete → first-boot check"
      case .installationMedia: "Installation media required"
      }
    }

    public var guidance: String {
      switch self {
      case .allocationClamped:
        "Choose a larger size, then apply it. The simulated limit returns to the original size. Confirm the displayed size resets and acknowledgement clears."
      case .missingHelper:
        "Approve the plan. Install must remain unavailable. Use Edit disk size to return to review."
      case .credentialsRejected:
        "Submit the test account. The first attempt is rejected; the next succeeds."
      case .connectionLost, .emptyReply, .helperFailure:
        "Check the last verified activity. Starting another installation must remain unavailable."
      case .recoveryRetry:
        "Retry Recovery using the test account. The simulation must not repeat disk preparation."
      case .shutdownFailure:
        "Request shutdown from Recovery. Confirm your Mac stays on and the steps remain visible."
      default:
        "Walk through the installer with test data. Check keyboard navigation, smaller windows, and activity details. Reset starts again."
      }
    }
  }

  /// An in-memory environment. It never constructs a live adapter, reads the
  /// host, opens a socket, invokes XPC, downloads files, or requests OS shutdown.
  /// Synthetic transcripts still pass through the real journal decoder.
  public final class InstallerSimulationEnvironment: InstallerEnvironment, @unchecked Sendable {
    public let scenario: InstallerSimulationScenario
    private let delay: Duration
    private let lock = NSLock()
    private var approved = false
    private var attempts = 0
    private var cancelled = false
    public let channel: ReleaseChannel

    public init(
      scenario: InstallerSimulationScenario, channel: ReleaseChannel = .stable,
      delay: Duration = .milliseconds(600)
    ) {
      self.scenario = scenario
      self.channel = channel
      self.delay = delay
    }

    public var isSimulation: Bool { true }
    public var installationBlocked: Bool { scenario == .unsupported }
    public var engineSupported: Bool { scenario != .unsupported && scenario != .engineUnavailable }
    public var hasApprovedPlan: Bool { lock.withLock { approved } }
    public var helperStatus: HelperDisplay {
      HelperDisplay(status: scenario == .missingHelper ? .notInstalled : .enabled)
    }
    public func refreshHelperStatus() -> HelperDisplay { helperStatus }
    public func cancel() { lock.withLock { cancelled = true } }

    private func tick() async throws {
      try Task.checkCancellation()
      guard !lock.withLock({ cancelled }) else { throw CancellationError() }
      if delay > .zero { try await Task.sleep(for: delay) }
      guard !lock.withLock({ cancelled }) else { throw CancellationError() }
    }

    public func inspect() async throws -> HostDisplay {
      try await tick()
      return HostDisplay(
        chipAndSpace: "Simulated Mac · 464 GB free", supported: engineSupported,
        blockingReason: scenario == .engineUnavailable ? PlainLanguage.engineUnavailable : nil,
        existingInstalls: scenario == .existingInstall
          ? [ExistingInstallDisplay(sourceIdentifier: "Simulated disk", sizeDescription: "137 GB")]
          : [])
    }

    public func preparePlan(
      omarchyBytes: UInt64?,
      progress: @escaping @Sendable (AssetProgressUpdate) -> Void
    ) async throws -> PlanPreparationDisplay {
      progress(AssetProgressUpdate(stage: .fetchingCatalog))
      try await tick()
      switch scenario {
      case .emptyChannel: throw InstallerReleaseConfigurationError.unexpectedHTTPStatus(404)
      case .outdatedInstaller:
        throw InstallerAssetPreparationError.installerOutdated(
          current: InstallerVersion(major: 1, minor: 0, patch: 0),
          minimum: InstallerVersion(major: 2, minor: 0, patch: 0),
          downloadURL: URL(string: "https://example.invalid/simulation")!)
      default: break
      }
      for step in 1...5 {
        progress(
          AssetProgressUpdate(
            stage: .downloading,
            rows: [
              AssetProgressRow(
                role: "payload", fileName: "Simulated Omarchy release",
                bytesCompleted: UInt64(step) * 800_000_000,
                totalBytes: 4_000_000_000, phase: step == 5 ? .verified : .downloading)
            ]))
        try await tick()
        if step == 2 && scenario == .downloadFailure { throw URLError(.networkConnectionLost) }
      }
      if scenario == .invalidDownload {
        throw ArtifactStageError.digestMismatch(
          expected: "simulation-expected", actual: "simulation-corrupt")
      }
      if scenario == .planFailure {
        throw InstallerAllocationRecommendationError.noEligibleCandidate
      }
      progress(AssetProgressUpdate(stage: .planning))
      try await tick()
      let initial: UInt64 = 137_438_953_472
      let maximum: UInt64 =
        scenario == .allocationClamped && omarchyBytes != nil ? initial : 700_000_000_000
      let requested = min(maximum, max(80_000_000_000, omarchyBytes ?? initial))
      let unit = PinnedAsahiPlanRequest.allocationUnitBytes
      let length = scenario == .allocationAligned ? requested - requested % unit : requested
      return .plan(
        PlanDisplay(
          diskTotalBytes: scenario == .freeSpace ? 900_000_000_000 : 994_662_584_320,
          omarchyBytes: length,
          bindingDigest: "simulation-\(length)", minimumBytes: 80_000_000_000,
          maximumBytes: maximum,
          releaseDescription:
            "SIMULATION · \(channel.rawValue.uppercased()) · Omarchy test release",
          targetDescription:
            "Simulated internal disk · \(scenario == .freeSpace ? "Use free space" : "Resize macOS container")",
          fixedMacOSBytes: scenario == .freeSpace ? 100_000_000_000 : nil))
    }

    public func approve() throws {
      if scenario == .approvalChanged { throw SimulationError.planChanged }
      lock.withLock { approved = true }
    }
    public func discardApproval() { lock.withLock { approved = false } }

    public func execute(
      operation: InstallOperationKind, authorization: MachineOwnerAuthorization,
      journal: @escaping @Sendable (Data) -> Void
    ) async throws -> CompletionDisplay {
      // The dummy authorization is deliberately never inspected or retained.
      guard hasApprovedPlan else { throw SimulationError.planChanged }
      let attempt = lock.withLock {
        attempts += 1
        return attempts
      }
      try await tick()
      if scenario == .credentialsRejected && attempt == 1 {
        throw EngineXPCSubmissionError.machineOwnerCredentialsRejected
      }
      if operation == .retryRecoveryAuthorization { return completion() }
      for (index, line) in Self.journalLines.enumerated() {
        try await tick()
        journal(scenario == .degradedProgress && index == 5 ? Data("broken\n".utf8) : line)
        if index == 5 {
          if scenario == .connectionLost { throw EngineXPCSubmissionError.connectionFailed }
          if scenario == .helperFailure {
            throw EngineXPCSubmissionError.helperRejected(domain: "Simulation", code: 1)
          }
          if scenario == .emptyReply { throw EngineXPCSubmissionError.emptyResponse }
        }
        if index == 7 && scenario == .recoveryRetry && operation == .install {
          throw EngineXPCSubmissionError.recoveryAuthorizationFailed
        }
      }
      return completion()
    }

    private func completion() -> CompletionDisplay {
      let next: InstallerNextAction =
        switch scenario {
        case .manualRecovery: .manualRecovery
        case .completed: .verifyInstalledSystem
        case .installationMedia: .attachInstallationMedia
        default: .enterRecovery
        }
      let handoff: HandoffDisplay? =
        next == .enterRecovery || next == .attachInstallationMedia
        ? HandoffDisplay(
          headline: next == .enterRecovery
            ? PlainLanguage.recoveryHeadline : PlainLanguage.mediaHeadline,
          steps: PlainLanguage.recoverySteps(for: [
            "enterOneTrueRecovery", "authenticateMachineOwner",
          ])) : nil
      return CompletionDisplay(
        nextAction: next, headline: PlainLanguage.doneHeadline,
        subheadline: PlainLanguage.nextActionMessage(next), verified: [], handoff: handoff)
    }

    public func requestShutdown() -> Bool { scenario != .shutdownFailure }

    enum SimulationError: Error { case planChanged }

    public static var journalLines: [Data] {
      LiveInstallJournalModel.lines(in: Data(syntheticJournal.utf8)).map { $0 + [0x0A] }
    }
    // Synthetic protocol records; no hardware evidence or reusable approval.
    private static let syntheticJournal = #"""
      {"payload":{"device_identifier":"apple,j314s","support":"supported"},"schema_version":1,"sequence":1,"type":"inspection"}
      {"payload":{"candidates":[{"kind":"resize","length_bytes":994662584320,"minimum_container_bytes":201113731072,"minimum_install_bytes":76562825216,"offset_bytes":524312576,"source_identifier":"disk0s2"}],"layout_digest":"sha256:45772bb3571562eea859a31406a494f4e1dcfc85928097af5e78e880ce94f7f0","system_store_identifier":"disk0"},"schema_version":1,"sequence":2,"type":"inventory"}
      {"payload":{"candidate_kind":"resize","device_identifier":"apple,j314s","engine_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","engine_version":"simulation","layout_digest":"sha256:45772bb3571562eea859a31406a494f4e1dcfc85928097af5e78e880ce94f7f0","length_bytes":137438953472,"metadata_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","offset_bytes":857747943424,"payload_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","plan_digest":"5aa8b12b40e4ad60d9ca4156f3a946bcf1f8e5f491185f40cff4f43b8d29272a","required_human_steps":["enterOneTrueRecovery","authenticateMachineOwner"],"source_identifier":"disk0s2","store_identifier":"disk0"},"schema_version":1,"sequence":3,"type":"plan"}
      {"payload":{"name":"apfs_preparation_started","plan_digest":"5aa8b12b40e4ad60d9ca4156f3a946bcf1f8e5f491185f40cff4f43b8d29272a"},"schema_version":1,"sequence":4,"type":"event"}
      {"payload":{"evidence_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","identifier":"apfs-target-prepared","phase":"apfs_preparation","plan_digest":"5aa8b12b40e4ad60d9ca4156f3a946bcf1f8e5f491185f40cff4f43b8d29272a"},"schema_version":1,"sequence":5,"type":"checkpoint"}
      {"payload":{"name":"stub_and_esp_started","plan_digest":"5aa8b12b40e4ad60d9ca4156f3a946bcf1f8e5f491185f40cff4f43b8d29272a"},"schema_version":1,"sequence":6,"type":"event"}
      {"payload":{"evidence_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","identifier":"stub-and-esp-installed","phase":"stub_and_esp","plan_digest":"5aa8b12b40e4ad60d9ca4156f3a946bcf1f8e5f491185f40cff4f43b8d29272a"},"schema_version":1,"sequence":7,"type":"checkpoint"}
      {"payload":{"name":"recovery_handoff_started","plan_digest":"5aa8b12b40e4ad60d9ca4156f3a946bcf1f8e5f491185f40cff4f43b8d29272a"},"schema_version":1,"sequence":8,"type":"event"}
      {"payload":{"evidence_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","identifier":"recovery-handoff-prepared","phase":"awaiting_recovery","plan_digest":"5aa8b12b40e4ad60d9ca4156f3a946bcf1f8e5f491185f40cff4f43b8d29272a"},"schema_version":1,"sequence":9,"type":"checkpoint"}
      {"payload":{"outcome":"awaiting_recovery","plan_digest":"5aa8b12b40e4ad60d9ca4156f3a946bcf1f8e5f491185f40cff4f43b8d29272a"},"schema_version":1,"sequence":10,"type":"completion"}
      """#
  }
#endif
