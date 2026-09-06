import AppKit
import OmarchyAppleInstallerTrustCore
import OmarchyInstallerUXCore
import SwiftUI

@MainActor
private final class InstallerApplicationDelegate: NSObject, NSApplicationDelegate {
  private var instanceLease: InstallerAppInstanceLease?

  func applicationWillFinishLaunching(_ notification: Notification) {
    #if !DEBUG
      if ProcessInfo.processInfo.arguments.contains("--simulate") {
        fputs("Simulation requires a debug build. Refusing to launch the live installer.\n", stderr)
        NSApplication.shared.terminate(nil)
        return
      }
    #endif
    do {
      let lockFile = try InstallerAppInstanceLease.defaultLockFileURL()
      instanceLease = try InstallerAppInstanceLease.acquire(at: lockFile)
    } catch {
      fputs("Omarchy MX Mac Installer refused a duplicate or unsafe launch: \(error)\n", stderr)
      NSApplication.shared.terminate(nil)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // The install ends with a shutdown the app itself requests. macOS would
    // otherwise treat it as an app open at shutdown and bring it back at the
    // next login, so someone rebooting from Omarchy into macOS met the
    // installer again. Opt out for good.
    NSApp.disableRelaunchOnLogin()

    #if DEBUG
      // A bare SwiftPM executable has no Info.plist, so Launch Services
      // registers it background-only and the window never appears. Promote
      // unbundled debug runs to a regular, frontmost app; the packaged app
      // is already regular and never enters this branch.
      if Bundle.main.bundleURL.pathExtension != "app" {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
      }
    #endif
  }
}

@main
struct OmarchyAppleInstallerApp: App {
  @NSApplicationDelegateAdaptor(InstallerApplicationDelegate.self)
  private var applicationDelegate

  /// Testers switch to the rc channel here. The choice only picks between the
  /// two URLs already signed into this build; changing it restarts the check so
  /// nothing planned against one channel is installed from the other.
  @State private var liveSession: InstallerSession?

  private var isSimulation: Bool {
    #if DEBUG
      return ProcessInfo.processInfo.arguments.contains("--simulate")
    #else
      return false
    #endif
  }

  @ViewBuilder
  private var installerContent: some View {
    #if DEBUG
      if isSimulation {
        SimulationDashboard()
      } else {
        liveContent
      }
    #else
      if ProcessInfo.processInfo.arguments.contains("--simulate") {
        ContentUnavailableView("Simulation requires a debug build", systemImage: "lock.shield")
      } else {
        liveContent
      }
    #endif
  }

  private var liveContent: some View {
    OnePageInstallerView(
      environment: InstallerEnvironmentFactory.make(), channel: channel,
      onSessionAvailable: { liveSession = $0 })
  }

  @State private var channel: ReleaseChannel = ReleaseChannelPreference()
    .resolve(descriptorDefault: .stable)

  var body: some Scene {
    WindowGroup(PlainLanguage.windowTitle) {
      installerContent
        .frame(minWidth: 640, minHeight: 600)
        .tint(OmarchyTheme.accent)
        // The window itself takes the theme colour, title bar included, so the
        // translucent system title bar never tints from the wallpaper behind.
        .containerBackground(OmarchyTheme.window, for: .window)
    }
    .defaultSize(width: 780, height: 850)
    .windowResizability(.contentMinSize)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandMenu(PlainLanguage.channelMenuTitle) {
        Picker(PlainLanguage.channelMenuTitle, selection: channelBinding) {
          Text(PlainLanguage.channelStable).tag(ReleaseChannel.stable)
          Text(PlainLanguage.channelRC).tag(ReleaseChannel.rc)
        }
        .pickerStyle(.inline)
        .disabled(liveSession?.canChangeChannel != true || isSimulation)
      }
    }
  }

  private var channelBinding: Binding<ReleaseChannel> {
    Binding(
      get: { channel },
      set: { selected in
        guard liveSession?.canChangeChannel == true && !isSimulation else { return }
        ReleaseChannelPreference().select(selected)
        channel = selected
      }
    )
  }
}
