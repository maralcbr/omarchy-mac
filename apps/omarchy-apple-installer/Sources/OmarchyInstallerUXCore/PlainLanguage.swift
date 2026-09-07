#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore

  /// Every user-visible string in the installer. Screens read from here so the
  /// wording can be reviewed in one place and unit-tested for completeness.
  public enum PlainLanguage {
    // MARK: Chrome

    public static let windowTitle = "Omarchy Installer"

    // MARK: Screen A — Check

    public static let checkSubheadline =
      "When setup is complete, you can choose Omarchy or macOS at startup."
    public static let checkContinue = "Continue"
    public static let checkAgain = "Check again"
    public static let inspectingHeadline = "Checking this Mac"
    public static let inspectingSubheadline =
      "Checking your Mac model, macOS version, power connection, FileVault, and available disk space."

    // MARK: Screen A2 — Existing install

    public static let existingInstallHeadline = "Omarchy is already installed"
    public static let closeInstaller = "Close"

    // MARK: Screen B — Plan

    public static func allocationNotice(requestedBytes: UInt64, actualBytes: UInt64) -> String? {
      let formatter = DiskSizeInput()
      let requested = formatter.display(requestedBytes)
      let actual = formatter.display(actualBytes)
      // Disk alignment changes bytes without changing the whole GB the user chose.
      guard requested != actual else { return nil }
      return
        "Space for Omarchy changed from \(requested) GB to \(actual) GB. Review the updated size before installing."
    }

    public static let replanning = "Checking the new size…"
    public static let planAcknowledgement =
      "I have a current backup and approve the disk sizes shown above."
    public static let planInstall = "Install"
    public static let downloadingPackagesTitle = "Downloading installation files"

    public static func preparingStageTitle(
      _ stage: AssetProgressUpdate.Stage
    ) -> String {
      switch stage {
      case .fetchingCatalog: "Checking the signed release…"
      case .downloading: "Downloading installation files…"
      case .inspectingEngine: "Checking disk compatibility…"
      case .planning: "Preparing your installation plan…"
      }
    }

    // MARK: Screen C — Authorize

    public static let authorizeTitle =
      "Authorize installation"
    public static let authorizeRetryTitle = "Authorize the Recovery step"
    public static let authorizeUsernameLabel = "macOS account name"
    public static let authorizeChecking = "Checking your credentials…"
    public static let authorizeStillWorking =
      "This can take a few minutes. After your credentials are accepted, the installer prepares the installation package."
    public static let authorizePasswordLabel = "macOS login password"
    public static let authorizeCancel = "Cancel"
    public static let authorizeRetryAction = "Authorize"
    public static let authorizeRejected =
      "The account name or password wasn’t accepted."

    // MARK: Confirmation dialogs (preserved verbatim)

    public static let recoveryRetryConfirmationTitle =
      "Retry the Recovery authorization step?"
    public static let recoveryRetryConfirmationBody =
      "The installer will verify the approved plan, installation files, disk location, and completed checkpoint before retrying Apple’s boot authorization. This retry cannot resize the disk, change partitions, or rewrite the installed system."
    public static let recoveryRetryConfirmationAction =
      "Retry Recovery authorization"
    public static let cancel = "Cancel"

    // MARK: Screen D — Install

    public static let installWarning =
      "Keep your Mac open and connected to power."
    public static let installDegraded =
      "Live progress is unavailable. The installer will verify the installation record when it receives a result."
    public static let installVerifyingOwner = "Checking your macOS account…"
    public static let installStageLabels = [
      "Preparing disk space", "Installing boot files",
      "Preparing the Recovery step",
    ]

    public static func installPhaseTitle(forPhase phase: String?) -> String {
      switch phase {
      case "preflight": "Checking the disk…"
      case "existing_removal": "Removing the previous Omarchy installation…"
      case "apfs_preparation": "Preparing disk space…"
      case "stub_and_esp": "Writing boot files…"
      case "awaiting_recovery": "Preparing the Recovery step…"
      case "boot_policy": "Authorizing startup…"
      case "media_handoff": "Preparing installation media…"
      case "omarchy_install": "Installing Omarchy…"
      default: installVerifyingOwner
      }
    }

    public static func installPhaseTitle(forEvent event: String?) -> String? {
      switch event {
      case "existing_removal_started": "Removing the previous Omarchy installation…"
      case "apfs_preparation_started": "Preparing disk space…"
      case "stub_and_esp_started": "Writing boot files…"
      case "recovery_handoff_started": "Preparing the Recovery step…"
      default: nil
      }
    }

    public static func checkpointSummary(_ identifier: String) -> String {
      switch identifier {
      case "existing-install-removed": "Previous Omarchy installation removed"
      case "apfs-target-prepared": "Disk space reserved for Omarchy"
      case "stub-and-esp-installed": "Installation files written"
      case "recovery-handoff-prepared": "Ready for Recovery"
      default: "Additional installation activity (\(identifier))"
      }
    }

    public static func eventSummary(_ name: String) -> String {
      switch name {
      case "existing_removal_started": "Started removing the previous Omarchy installation"
      case "apfs_preparation_started": "Started preparing disk space"
      case "stub_and_esp_started": "Started writing boot files"
      case "recovery_handoff_started": "Started preparing the Recovery step"
      default: "Additional installation activity (\(name))"
      }
    }

    // MARK: Screen E — Recovery

    public static let recoveryHeadline = "Finish setup in Recovery"
    public static let recoveryShutDown = "Shut down"
    public static let shutdownConfirmationTitle = "Shut down this Mac now?"
    public static let shutdownConfirmationBody =
      "Save your work before shutting down. When your Mac is off, hold the power button until “Loading startup options” appears. Choose Omarchy → Finish Installation, then sign in with your macOS account."
    public static let shutdownConfirmationAction = "Shut down"
    public static let mediaHeadline = "Connect the installation media"

    /// Numbered plain-language steps for the signed `requiredHumanSteps`
    /// tokens. Unknown tokens are surfaced rather than dropped.
    public static func recoverySteps(
      for requiredHumanSteps: [String]
    ) -> [RecoveryStep] {
      var steps = [RecoveryStep]()
      var number = 1
      func append(_ title: String) {
        steps.append(RecoveryStep(number: number, title: title))
        number += 1
      }
      for token in requiredHumanSteps {
        switch token {
        case "enterOneTrueRecovery":
          append("Shut down")
          append(
            "When your Mac is off, press and hold the power button until startup options appear.")
        case "authenticateMachineOwner":
          append("Choose Omarchy → Finish Installation, then sign in with your macOS account.")
        default:
          append(
            "Unsupported Recovery instruction: \(token). Save the installation record and get support before continuing."
          )
        }
      }
      if steps.isEmpty {
        append("Shut down")
        append("Hold the power button until startup options appear.")
        append("Choose Omarchy → Finish Installation, then sign in with your macOS account.")
      }
      return steps
    }

    // MARK: Screen F — Boot / completion

    public static let doneHeadline = "Omarchy is installed"
    public static let startOver = "Start over"
    public static let downloadInstaller = "Download the installer"
    public static let rcBadge = "RELEASE CANDIDATE"
    public static let channelMenuTitle = "Release channel"
    public static let channelStable = "Stable"
    public static let channelRC = "Release candidate"
    public static let doneVerifiedRows = [
      PlanFactRow(label: "Startup sequence", value: "m1n1 → U-Boot → GRUB → Omarchy"),
      PlanFactRow(
        label: "File verification",
        value: "Release verified; installation files written"
      ),
    ]

    public static func nextActionMessage(
      _ action: InstallerNextAction
    ) -> String {
      switch action {
      case .continueInstallation:
        "Your approved plan was accepted. Installation is continuing."
      case .enterRecovery:
        "Omarchy’s files are installed. Finish setup in Recovery to allow your Mac to start Omarchy."
      case .attachInstallationMedia:
        "Preparation is complete. Connect the verified installation media to continue."
      case .verifyInstalledSystem:
        "Installation is complete. Start Omarchy and check that it works."
      case .manualRecovery:
        "Installation needs manual recovery before it can continue."
      }
    }

    // MARK: Blocked

    public static let blockedHeadline = "This Mac isn’t supported yet"
    public static let blockedSubheadline =
      "This Mac model has not been approved for this release."
    public static let blockedExplainer =
      "Each Mac model requires physical testing before it is included in a signed installer release. Catalog updates can withdraw support; adding a model requires a new signed release."
    public static let blockedBadge = "Not supported"
    public static let notReadyHeadline = "This Mac isn’t ready yet"
    public static let notReadyDetail =
      "The installer couldn’t confirm that this Mac meets the installation requirements."
    public static let supportedBadge = "Supported"

    // MARK: Errors

    public static let retry = "Try again"

    /// Shown when the pre-installed system daemon is missing. The remedy is to
    /// run the installer package again — never to open Login Items.
    public static let helperNotInstalled =
      "The system installation service is missing. Run the Omarchy installer package again, then reopen this app."

    public static let engineUnavailable =
      "This build is missing the required validation engine. Installation is unavailable."
    public static let engineIdentityMismatch =
      "The validation engine failed an identity check. Installation is unavailable."
    public static let releaseResourcesUnavailable =
      "This build is missing a verified production release identity. Installation is unavailable."
    public static let planChangedBeforeApproval =
      "The installation plan changed. Prepare and review the new plan before continuing."
    public static let approvalUnavailable =
      "The approved plan or installation service is no longer available. Prepare and review the plan again."
    public static let retryCheckpointUnavailable =
      "The verified checkpoint needed to retry Recovery authorization is unavailable. Installation remains stopped."
    public static let inspectionRequired =
      "Complete the Mac and disk checks before continuing."

    /// Maps a thrown error to the four-part failure card the screens render.
    /// `technicalDetail` always preserves `String(describing:)` so nothing is
    /// lost behind the plain-language headline.
    public static func failure(
      for error: any Error,
      retryRecoveryAvailable: Bool = false
    ) -> FailureDisplay {
      let technical = String(describing: error)

      if retryRecoveryAvailable {
        return FailureDisplay(
          headline: "Recovery authorization didn’t complete",
          plainDetail:
            "Disk preparation and file installation were verified. Retry the Recovery authorization step.",
          technicalDetail: technical,
          remedy:
            "Enter the authorized macOS account password again. Only the Recovery authorization step will be retried.",
          retryRecoveryAvailable: true
        )
      }

      if let submission = error as? EngineXPCSubmissionError {
        switch submission {
        case .machineOwnerCredentialsRejected:
          return FailureDisplay(
            headline: authorizeRejected,
            plainDetail:
              "Your credentials were rejected before this request could change the disk.",
            technicalDetail: technical,
            remedy:
              "Enter the account name and password of a macOS account authorized to install on this Mac."
          )
        case .recoveryAuthorizationFailed:
          return FailureDisplay(
            headline: "Recovery authorization didn’t complete",
            plainDetail:
              "Disk preparation and file installation were verified. Recovery authorization is still required.",
            technicalDetail: technical,
            remedy: "Retry only the Recovery authorization step."
          )
        case .helperUnresponsive:
          return FailureDisplay(
            headline: "The installation service isn’t responding",
            plainDetail:
              "The app couldn’t get a response from the installation service. Installation has not started.",
            technicalDetail: technical,
            remedy: "Run the Omarchy installer package again, then reopen this app."
          )
        case .connectionFailed:
          return FailureDisplay(
            headline: "Connection to the installation service was lost",
            plainDetail:
              "Disk changes may have started. The app cannot yet confirm the installation result.",
            technicalDetail: technical,
            remedy:
              "Keep your Mac connected to power. Save the error details and check the verified installation record before trying again."
          )
        case .helperRejected(let domain, let code):
          let busy = ClosedEngineHelperError.busy as NSError
          if domain == busy.domain, code == busy.code {
            return FailureDisplay(
              headline: "An installation may already be running",
              plainDetail:
                "Keep your Mac powered on. An installation may still be running; check its installation record before starting another attempt.",
              technicalDetail: technical
            )
          }
          return FailureDisplay(
            headline: "The installation service couldn’t complete the request",
            plainDetail:
              "The service returned an error. The app cannot confirm whether disk changes have started.",
            technicalDetail: technical,
            remedy:
              "Save the error details and check the verified installation record before trying again."
          )
        default:
          return FailureDisplay(
            headline: "The installation result is unknown",
            plainDetail:
              "The installation service did not return a verified result. Disk changes may have started.",
            technicalDetail: technical,
            remedy:
              "Save the error details and check the verified installation record before trying again."
          )
        }
      }

      if let helper = error as? ClosedEngineHelperError {
        switch helper {
        case .busy:
          return FailureDisplay(
            headline: "An installation may already be running",
            plainDetail:
              "Keep your Mac powered on. Check the existing installation before trying again.",
            technicalDetail: technical
          )
        case .invalidMachineOwnerCredentials:
          return FailureDisplay(
            headline: authorizeRejected,
            plainDetail: "This request did not change the disk.",
            technicalDetail: technical
          )
        case .unsupportedDevice(let identifier):
          return FailureDisplay(
            headline: blockedHeadline,
            plainDetail: blockedSubheadline,
            technicalDetail: technical,
            remedy: "This release does not support Mac model \(identifier).",
            isBlockedModel: true
          )
        default:
          return FailureDisplay(
            headline: "The installation service reported an error",
            plainDetail:
              "Check the last verified installation step to see what completed.",
            technicalDetail: technical,
            remedy:
              "Save the error details and check the verified installation record before trying again."
          )
        }
      }

      if error is InstallerAllocationRecommendationError {
        return FailureDisplay(
          headline: "There isn’t enough usable disk space",
          plainDetail:
            "The installer couldn’t find a disk allocation that meets its requirements. The disk has not been changed.",
          technicalDetail: technical, remedy: "Free up space in macOS, then check again.")
      }
      if error is URLError {
        return FailureDisplay(
          headline: "The network request didn’t finish",
          plainDetail: "Check your internet connection before continuing.",
          technicalDetail: technical, remedy: "Check your internet connection, then try again.")
      }

      if let preparation = error as? InstallerPlanPreparationError {
        switch preparation {
        case .unsupportedDevice:
          return FailureDisplay(
            headline: blockedHeadline,
            plainDetail: blockedSubheadline,
            technicalDetail: technical,
            isBlockedModel: true
          )
        default:
          return FailureDisplay(
            headline: "An installation plan couldn’t be prepared",
            plainDetail:
              "The installer couldn’t prepare a valid disk plan. Installation has not started.",
            technicalDetail: technical,
            remedy: "Review the error details, then check this Mac again."
          )
        }
      }

      if let preparation = error as? InstallerAssetPreparationError {
        switch preparation {
        case .installerOutdated(let current, let minimum, let downloadURL):
          return FailureDisplay(
            headline: "This installer is out of date",
            plainDetail:
              "This release requires installer \(minimum) or later. You’re using \(current).",
            technicalDetail: technical,
            remedy:
              "Download and run the latest installer package, then reopen this app.",
            actionURL: downloadURL,
            actionTitle: downloadInstaller
          )
        case .hostBlocked(let reason):
          return FailureDisplay(
            headline: "This Mac isn’t supported yet",
            plainDetail: reason,
            technicalDetail: technical,
            isBlockedModel: true
          )
        case .unsupportedDevice(let identifier):
          return FailureDisplay(
            headline: "This release doesn’t support this Mac",
            plainDetail:
              "Mac model \(identifier) is not listed in this release’s signed support catalog.",
            technicalDetail: technical,
            isBlockedModel: true
          )
        case .deliveryMetadataUnavailable:
          return FailureDisplay(
            headline: "Installation files aren’t listed for this Mac",
            plainDetail:
              "The signed release supports this Mac but doesn’t provide its installation file details. Installation cannot continue.",
            technicalDetail: technical,
            remedy: "Check again later."
          )
        }
      }

      if let staging = error as? ArtifactStageError {
        switch staging {
        case .digestMismatch, .sizeMismatch, .destinationConflict,
          .partSizeSumMismatch:
          return FailureDisplay(
            headline: "An installation file couldn’t be verified",
            plainDetail:
              "The file did not pass verification. Installation cannot continue.",
            technicalDetail: technical,
            remedy: "Try downloading the installation files again."
          )
        default:
          return FailureDisplay(
            headline: "The installation files couldn’t be prepared",
            plainDetail: "Installation has not started.",
            technicalDetail: technical,
            remedy: "Review the error details, then try again."
          )
        }
      }

      if let configuration = error as? InstallerReleaseConfigurationError {
        switch configuration {
        case .releaseResourcesUnavailable:
          return FailureDisplay(
            headline: "Installation is unavailable in this build",
            plainDetail: releaseResourcesUnavailable,
            technicalDetail: technical
          )
        case .unexpectedHTTPStatus(404):
          return FailureDisplay(
            headline: "No release is available on this channel",
            plainDetail:
              "No downloadable release was found on the selected channel.",
            technicalDetail: technical,
            remedy:
              "Choose another release channel from the menu bar, or check again later."
          )
        case .unexpectedHTTPStatus:
          return FailureDisplay(
            headline: "The release server returned an error",
            plainDetail: "Installation has not started.",
            technicalDetail: technical,
            remedy: "Review the error details, then try again."
          )
        case .invalidCatalogEnvelope, .invalidCatalogSignature,
          .oversizedDocument:
          return FailureDisplay(
            headline: "The release couldn’t be verified",
            plainDetail:
              "The server response did not pass release verification. Installation cannot continue.",
            technicalDetail: technical,
            remedy: "Check again later."
          )
        default:
          return FailureDisplay(
            headline: "The release is unavailable",
            plainDetail: "Installation has not started.",
            technicalDetail: technical,
            remedy: "Review the error details, then try again."
          )
        }
      }

      if let catalog = error as? SupportCatalogError {
        return FailureDisplay(
          headline: "The support catalog couldn’t be verified",
          plainDetail:
            "The catalog did not meet the installer’s signature or version requirements. Installation cannot continue.",
          technicalDetail: String(describing: catalog),
          remedy: "Try again later, or download the latest installer."
        )
      }

      return FailureDisplay(
        headline: "The installer encountered an error",
        plainDetail:
          "Review the last verified installation step before continuing.",
        technicalDetail: technical,
        remedy:
          "If installation has started, keep your Mac connected to power and check the verified installation record before trying again."
      )
    }

    // MARK: Formatting

    /// Whole-number sizes: "137 GB", "18 MB". Decimal places only add noise
    /// at the scale people choose disk space in.
    public static func bytes(_ value: UInt64) -> String {
      let gb: Double = 1_000_000_000
      let mb: Double = 1_000_000
      let kb: Double = 1_000
      let count = Double(value)
      if count >= gb { return "\(Int((count / gb).rounded())) GB" }
      if count >= mb { return "\(Int((count / mb).rounded())) MB" }
      if count >= kb { return "\(Int((count / kb).rounded())) KB" }
      return "\(value) bytes"
    }

    public static func shortDigest(_ value: String) -> String {
      let body =
        value.hasPrefix("sha256:")
        ? String(value.dropFirst(7)) : value
      guard body.count > 20 else {
        return body
      }
      return String(body.prefix(8)) + "…" + String(body.suffix(8))
    }
  }
#endif
