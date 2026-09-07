#if DEBUG
  import SwiftUI
  import OmarchyInstallerUXCore
  import OmarchyAppleInstallerTrustCore

  /// Only constructed by the explicit --simulate launch flag. Scenario resets
  /// replace an in-memory environment; the live factory is never called.
  struct SimulationDashboard: View {
    var onSessionAvailable: ((InstallerSession) -> Void)? = nil
    var onColorSchemeChange: ((Bool) -> Void)? = nil
    @State private var scenario = InstallerSimulationScenario.success
    @State private var channel = ReleaseChannel.stable
    @State private var slow = false
    @State private var dark = true
    @State private var generation = UUID()
    @State private var environment = InstallerSimulationEnvironment(scenario: .success)
    @State private var canChangeChannel = false

    var body: some View {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 10) {
          Text("SIMULATION · No installation changes to your Mac")
            .font(.headline)
          HStack {
            Picker("Scenario", selection: $scenario) {
              ForEach(InstallerSimulationScenario.allCases) { scenario in
                Text(scenario.title).tag(scenario)
              }
            }
            Button("Reset simulation", action: reset)
          }
          HStack {
            Picker("Test channel", selection: $channel) {
              Text("Stable").tag(ReleaseChannel.stable)
              Text("Release candidate").tag(ReleaseChannel.rc)
            }.disabled(!canChangeChannel)
            Toggle("Slow playback", isOn: $slow)
            Toggle("Dark mode", isOn: $dark)
          }
          Text(scenario.guidance).font(.callout).fixedSize(horizontal: false, vertical: true)
          Text(
            "Test data only: no downloads, disk changes, or shutdown. Changing the scenario or speed restarts the simulation."
          )
          .font(.caption)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(OmarchyTheme.text)
        .background(OmarchyTheme.card)
        Divider()
        OnePageInstallerView(
          environment: environment, channel: channel,
          onChannelAvailability: { canChangeChannel = $0 },
          onSessionAvailable: { onSessionAvailable?($0) }
        )
        .id(generation)
      }
      .preferredColorScheme(dark ? .dark : .light)
      .onChange(of: dark) { _, value in onColorSchemeChange?(value) }
      .onChange(of: scenario) { _, _ in reset() }
      .onChange(of: slow) { _, _ in reset() }
      .onChange(of: channel) { _, _ in reset() }
    }

    private func reset() {
      environment.cancel()
      environment = InstallerSimulationEnvironment(
        scenario: scenario, channel: channel,
        delay: slow ? .seconds(2) : .milliseconds(400))
      generation = UUID()
      canChangeChannel = false
    }
  }
#endif
