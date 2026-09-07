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
      "After the installation you will be able to boot start Omarchy or MacOS."
    public static let checkContinue = "Continue"
    public static let checkAgain = "Check again"
    public static let inspectingHeadline = "Checking this Mac"
    public static let inspectingSubheadline =
      "Reading the model, MacOS version, power, FileVault, and free space."

    // MARK: Screen A2 — Existing install

    public static let existingInstallHeadline = "Omarchy is already installed on this Mac."
    public static let closeInstaller = "Close"

    // MARK: Screen B — Plan

    public static let replanning = "Updating the plan for that size…"
    public static let planAcknowledgement =
      "I am ready to partition my ssd and install."
    public static let planInstall = "Install"
    public static let downloadingPackagesTitle = "Downloading the Omarchy packages"

    public static func preparingStageTitle(
      _ stage: AssetProgressUpdate.Stage
    ) -> String {
      switch stage {
      case .fetchingCatalog: "Checking the signed catalog…"
      case .downloading: "Downloading verified files…"
      case .inspectingEngine: "Asking the pinned engine about this disk…"
      case .planning: "Building the exact plan…"
      }
    }

    // MARK: Screen C — Authorize

    public static let authorizeTitle =
      "Authorize the changes"
    public static let authorizeRetryTitle = "Retry Recovery authorization."
    public static let authorizeUsernameLabel = "Username"
    public static let authorizeChecking = "Verifying"
    public static let authorizeStillWorking =
      "Still working. Once the password is accepted the installer package is prepared, which takes a few minutes."
    public static let authorizePasswordLabel = "Password"
    public static let authorizeCancel = "Cancel"
    public static let authorizeRetryAction = "Authorize"
    public static let authorizeRejected =
      "The user name or password is not correct."

    // MARK: Confirmation dialogs (preserved verbatim)

    public static let recoveryRetryConfirmationTitle =
      "Retry only Recovery authorization?"
    public static let recoveryRetryConfirmationBody =
      "The helper will revalidate the exact plan, artifacts, disk extent, and completed read-back checkpoint, then rerun only Apple’s boot-policy authorization. It cannot resize, repartition, or rewrite the installed system."
    public static let recoveryRetryConfirmationAction =
      "Retry Recovery authorization"
    public static let cancel = "Cancel"

    // MARK: Screen D — Install

    public static let installWarning =
      "Keep the lid open and power connected."
    public static let installDegraded =
      "Live progress is unavailable. The installation continues; the sealed journal is still verified when it finishes."
    public static let installVerifyingOwner = "Verifying machine owner…"
    public static let installStageLabels = [
      "Preparing the space", "Installing the boot files",
      "Handing off to Recovery",
    ]

    public static func installPhaseTitle(forPhase phase: String?) -> String {
      switch phase {
      case "preflight": "Checking the disk…"
      case "existing_removal": "Removing the old Omarchy…"
      case "apfs_preparation": "Preparing space…"
      case "stub_and_esp": "Writing boot files…"
      case "awaiting_recovery": "Handing off to Recovery…"
      case "boot_policy": "Setting the boot policy…"
      case "media_handoff": "Handing off installation media…"
      case "omarchy_install": "Installing Omarchy…"
      default: installVerifyingOwner
      }
    }

    public static func installPhaseTitle(forEvent event: String?) -> String? {
      switch event {
      case "existing_removal_started": "Removing the old Omarchy…"
      case "apfs_preparation_started": "Preparing space…"
      case "stub_and_esp_started": "Writing boot files…"
      case "recovery_handoff_started": "Handing off to Recovery…"
      default: nil
      }
    }

    public static func checkpointSummary(_ identifier: String) -> String {
      switch identifier {
      case "existing-install-removed": "The old Omarchy is removed"
      case "apfs-target-prepared": "Space for Omarchy is reserved"
      case "stub-and-esp-installed": "Boot files are written and verified"
      case "recovery-handoff-prepared": "Ready for the Recovery step"
      default: identifier
      }
    }

    public static func eventSummary(_ name: String) -> String {
      switch name {
      case "existing_removal_started": "Started removing the old Omarchy"
      case "apfs_preparation_started": "Started preparing space"
      case "stub_and_esp_started": "Started writing boot files"
      case "recovery_handoff_started": "Started the Recovery handoff"
      default: name.replacingOccurrences(of: "_", with: " ")
      }
    }

    // MARK: Screen E — Recovery

    public static let recoveryHeadline = "Follow the steps below to install"
    public static let recoveryShutDown = "Shutdown your Mac"
    public static let shutdownConfirmationTitle = "Shut down this Mac now?"
    public static let shutdownConfirmationBody =
      "After it turns off, hold the power button until “Loading startup options” appears, then pick Omarchy → Finish Installation and sign in."
    public static let shutdownConfirmationAction = "Shut Down"
    public static let mediaHeadline = "Attach the installation media"

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
          append("After the Mac is off, hold the power button until startup options appear")
        case "authenticateMachineOwner":
          append("Pick Omarchy → Finish Installation")
        default:
          append(token)
        }
      }
      if steps.isEmpty {
        append("Shut down")
        append("Hold the power button")
        append("Pick Omarchy → Finish Installation")
      }
      return steps
    }

    // MARK: Screen F — Boot / completion

    public static let doneHeadline = "Omarchy is installed"
    public static let startOver = "Start over"
    public static let downloadInstaller = "Download the installer"
    public static let rcBadge = "BETA"
    public static let rcAuroraBadge = "AURORA"

    /// What the header says a pre-release install is. Stable carries no badge.
    public static func badge(for channel: ReleaseChannel) -> String {
      switch channel {
      case .stable: ""
      case .rc: rcBadge
      case .rcAurora: rcAuroraBadge
      }
    }
    public static let channelMenuTitle = "Release Channel"
    public static let channelStable = "Stable"
    public static let channelRC = "RC"
    public static let channelRCAurora = "RC (Aurora)"
    public static let doneVerifiedRows = [
      PlanFactRow(label: "Boot chain", value: "m1n1 → U-Boot → GRUB → Omarchy"),
      PlanFactRow(
        label: "Read-back",
        value: "installed files re-hashed and matched"
      ),
      PlanFactRow(label: "MacOS", value: "untouched, full security"),
      PlanFactRow(label: "Recovery", value: "partition intact"),
    ]

    public static func nextActionMessage(
      _ action: InstallerNextAction
    ) -> String {
      switch action {
      case .continueInstallation:
        "The helper accepted the exact plan and installation is continuing."
      case .enterRecovery:
        "The complete Omarchy system is installed. Shut down, hold the power button to enter 1TR Recovery, then run Finish Installation to establish boot policy."
      case .attachInstallationMedia:
        "Preparation completed. Attach the verified installation media to continue."
      case .verifyInstalledSystem:
        "Installation completed. Boot and verify the installed Omarchy system."
      case .manualRecovery:
        "The engine stopped safely and requires manual recovery before continuing."
      }
    }

    // MARK: Blocked

    public static let blockedHeadline = "This Mac isn’t supported yet"
    public static let blockedSubheadline =
      "Each model is tested and signed off individually. Nothing was downloaded or changed."
    public static let blockedExplainer =
      "The model list is signed and fails closed. Updates can remove a model, never add one. New models arrive only in a new signed release, after physical testing."
    public static let blockedBadge = "Blocked"
    public static let notReadyHeadline = "This Mac isn’t ready yet"
    public static let notReadyDetail =
      "Nothing was downloaded or changed. The pinned engine could not confirm this Mac."
    public static let supportedBadge = "Supported"

    // MARK: Errors

    public static let retry = "Retry…"

    /// Shown when the pre-installed system daemon is missing. The remedy is to
    /// run the installer package again — never to open Login Items.
    public static let helperNotInstalled =
      "The privileged helper is not installed. Run the Omarchy installer package again to install it, then reopen this app."

    public static let engineUnavailable =
      "Pinned validation engine is not available in this build. Installation remains locked."
    public static let engineIdentityMismatch =
      "Pinned engine identity did not match this Mac. Installation remains locked."
    public static let releaseResourcesUnavailable =
      "This build has no sealed production release identity. Installation remains locked."
    public static let planChangedBeforeApproval =
      "The plan changed before approval. Prepare and review it again."
    public static let approvalUnavailable =
      "The approved plan or enabled helper is no longer available. Prepare and review the plan again."
    public static let retryCheckpointUnavailable =
      "The exact Recovery retry checkpoint is no longer available. Installation remains stopped."
    public static let inspectionRequired =
      "Read-only host and engine inspection must complete first."

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
            "The disk work finished and was verified. MacOS still boots. Retry the last step.",
          technicalDetail: technical,
          remedy:
            "Re-enter the machine-owner password to retry only the checkpoint-bound boot-policy handoff.",
          retryRecoveryAvailable: true
        )
      }

      if let submission = error as? EngineXPCSubmissionError {
        switch submission {
        case .machineOwnerCredentialsRejected:
          return FailureDisplay(
            headline: authorizeRejected,
            plainDetail:
              "Nothing was changed. The helper checks the password before any disk work starts.",
            technicalDetail: technical,
            remedy: "Enter the machine owner’s MacOS user name and password again."
          )
        case .recoveryAuthorizationFailed:
          return FailureDisplay(
            headline: "Recovery authorization didn’t complete",
            plainDetail:
              "The disk work finished and was verified. MacOS still boots.",
            technicalDetail: technical,
            remedy: "Retry only the Recovery authorization step."
          )
        case .helperUnresponsive:
          return FailureDisplay(
            headline: "The privileged helper is not responding",
            plainDetail:
              "Nothing was changed. The helper was asked to start but did not answer, which usually means its installation is broken.",
            technicalDetail: technical,
            remedy: "Reinstall the Omarchy installer package, then reopen this app."
          )
        case .connectionFailed:
          return FailureDisplay(
            headline: "The privileged helper is not reachable",
            plainDetail:
              "Nothing was changed. The helper is installed by the Omarchy installer package and runs as a system service.",
            technicalDetail: technical,
            remedy: "Run the Omarchy installer package again, then try again."
          )
        case .helperRejected(let domain, let code):
          let busy = ClosedEngineHelperError.busy as NSError
          if domain == busy.domain, code == busy.code {
            return FailureDisplay(
              headline: "An installation appears to be in progress",
              plainDetail:
                "Do not power off this Mac. Quit the app and reopen it later; the running installation keeps its own journal.",
              technicalDetail: technical
            )
          }
          return FailureDisplay(
            headline: "The privileged helper refused this request",
            plainDetail:
              "Nothing was changed. The helper revalidates the plan, the artifacts, and this Mac before doing any work.",
            technicalDetail: technical,
            remedy: "Prepare and review the plan again."
          )
        default:
          return FailureDisplay(
            headline: "The installation could not start",
            plainDetail:
              "Nothing was changed. The request was rejected before any disk work.",
            technicalDetail: technical,
            remedy: "Prepare and review the plan again."
          )
        }
      }

      if let helper = error as? ClosedEngineHelperError {
        switch helper {
        case .busy:
          return FailureDisplay(
            headline: "An installation appears to be in progress",
            plainDetail:
              "Do not power off this Mac. Quit the app and reopen it later.",
            technicalDetail: technical
          )
        case .invalidMachineOwnerCredentials:
          return FailureDisplay(
            headline: authorizeRejected,
            plainDetail: "Nothing was changed.",
            technicalDetail: technical
          )
        case .unsupportedDevice(let identifier):
          return FailureDisplay(
            headline: blockedHeadline,
            plainDetail: blockedSubheadline,
            technicalDetail: technical,
            remedy: "Model \(identifier) is not in the signed catalog.",
            isBlockedModel: true
          )
        default:
          return FailureDisplay(
            headline: "The privileged helper stopped the installation",
            plainDetail:
              "The engine transcript did not match the approved plan, so nothing continued.",
            technicalDetail: technical,
            remedy: "Prepare and review the plan again."
          )
        }
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
            headline: "The plan could not be built",
            plainDetail:
              "Nothing was downloaded or changed beyond verified files. The pinned engine did not offer a usable place for Omarchy.",
            technicalDetail: technical,
            remedy: "Free up space in MacOS, then check again."
          )
        }
      }

      if let preparation = error as? InstallerAssetPreparationError {
        switch preparation {
        case .installerOutdated(let current, let minimum, let downloadURL):
          return FailureDisplay(
            headline: "This installer is out of date",
            plainDetail:
              "Nothing was downloaded. Omarchy now needs installer \(minimum) or newer, and this one is \(current).",
            technicalDetail: technical,
            remedy:
              "Download the current installer, run it, then open the app again.",
            actionURL: downloadURL,
            actionTitle: downloadInstaller
          )
        case .hostBlocked(let reason):
          return FailureDisplay(
            headline: "This Mac is not supported yet",
            plainDetail: reason,
            technicalDetail: technical,
            isBlockedModel: true
          )
        case .unsupportedDevice(let identifier):
          return FailureDisplay(
            headline: "This Mac is not in the signed catalog",
            plainDetail:
              "Nothing was downloaded. The signed catalog does not list \(identifier).",
            technicalDetail: technical,
            isBlockedModel: true
          )
        case .deliveryMetadataUnavailable:
          return FailureDisplay(
            headline: "The signed catalog is incomplete",
            plainDetail:
              "It names this Mac but not the files to install, so nothing was downloaded.",
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
            headline: "A downloaded file did not match the signed catalog",
            plainDetail:
              "The file was discarded. Nothing was installed and nothing was changed.",
            technicalDetail: technical,
            remedy: "Check again to download the files fresh."
          )
        default:
          return FailureDisplay(
            headline: "The verified download did not complete",
            plainDetail: "Nothing was installed and nothing was changed.",
            technicalDetail: technical,
            remedy: "Check your network connection and try again."
          )
        }
      }

      if let configuration = error as? InstallerReleaseConfigurationError {
        switch configuration {
        case .releaseResourcesUnavailable:
          return FailureDisplay(
            headline: "This build cannot install anything",
            plainDetail: releaseResourcesUnavailable,
            technicalDetail: technical
          )
        case .unexpectedHTTPStatus(404):
          return FailureDisplay(
            headline: "No Omarchy release was found",
            plainDetail:
              "This release channel has nothing published yet, so there was nothing to download.",
            technicalDetail: technical,
            remedy:
              "Try another channel under Release Channel in the menu bar, or check again later."
          )
        case .unexpectedHTTPStatus:
          return FailureDisplay(
            headline: "The release server did not answer properly",
            plainDetail: "Nothing was downloaded and nothing was changed.",
            technicalDetail: technical,
            remedy: "Check your network connection and try again."
          )
        case .invalidCatalogEnvelope, .invalidCatalogSignature,
          .oversizedDocument:
          return FailureDisplay(
            headline: "The published release could not be read",
            plainDetail:
              "What the server returned was not a valid signed release, so nothing was downloaded.",
            technicalDetail: technical,
            remedy: "Check again later."
          )
        default:
          return FailureDisplay(
            headline: "The release could not be reached",
            plainDetail: "Nothing was downloaded and nothing was changed.",
            technicalDetail: technical,
            remedy: "Check your network connection and try again."
          )
        }
      }

      if let catalog = error as? SupportCatalogError {
        return FailureDisplay(
          headline: "The signed catalog was rejected",
          plainDetail:
            "Nothing was downloaded. The catalog must be signed, current, and newer than the one already accepted.",
          technicalDetail: String(describing: catalog),
          remedy: "Try again later, or install a newer signed release."
        )
      }

      return FailureDisplay(
        headline: "The installation stopped safely",
        plainDetail:
          "Review the last trusted checkpoint before continuing. Nothing continues automatically.",
        technicalDetail: technical,
        remedy: "Start over to inspect this Mac again."
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
