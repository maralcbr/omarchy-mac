import AppKit
import OmarchyAppleInstallerTrustCore
import OmarchyInstallerUXCore
import SwiftUI

@MainActor
private final class InstallerApplicationDelegate: NSObject, NSApplicationDelegate {
  private var instanceLease: InstallerAppInstanceLease?

  func applicationWillFinishLaunching(_ notification: Notification) {
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
  @State private var channel: ReleaseChannel = ReleaseChannelPreference()
    .resolve(descriptorDefault: .stable)

  var body: some Scene {
    WindowGroup(PlainLanguage.windowTitle) {
      OnePageInstallerView(
        environment: InstallerEnvironmentFactory.make(),
        channel: channel
      )
      .frame(minWidth: 640, minHeight: 600)
      .tint(OmarchyTheme.accent)
      // The window itself takes the theme colour, title bar included, so the
      // translucent system title bar never tints from the wallpaper behind.
      .containerBackground(OmarchyTheme.window, for: .window)
    }
    .defaultSize(width: 720, height: 660)
    .windowResizability(.contentMinSize)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandMenu(PlainLanguage.channelMenuTitle) {
        Picker(PlainLanguage.channelMenuTitle, selection: channelBinding) {
          Text(PlainLanguage.channelStable).tag(ReleaseChannel.stable)
          Text(PlainLanguage.channelRC).tag(ReleaseChannel.rc)
        }
        .pickerStyle(.inline)
      }
    }
  }

  private var channelBinding: Binding<ReleaseChannel> {
    Binding(
      get: { channel },
      set: { selected in
        ReleaseChannelPreference().select(selected)
        channel = selected
      }
    )
  }
}
