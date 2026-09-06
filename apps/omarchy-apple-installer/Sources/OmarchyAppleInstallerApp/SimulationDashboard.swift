#if DEBUG
  import SwiftUI
  import OmarchyInstallerUXCore
  import OmarchyAppleInstallerTrustCore

  /// Only constructed by the explicit --simulate launch flag. Scenario resets
  /// replace an in-memory environment; the live factory is never called.
  struct SimulationDashboard: View {
    @State private var scenario = InstallerSimulationScenario.success
    @State private var channel = ReleaseChannel.stable
    @State private var slow = false
    @State private var dark = false
    @State private var generation = UUID()
    @State private var environment = InstallerSimulationEnvironment(scenario: .success)
    @State private var canChangeChannel = false

    var body: some View {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 10) {
          Text("SIMULATION · This Mac will not be changed")
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
              Text("RC").tag(ReleaseChannel.rc)
            }.disabled(!canChangeChannel)
            Toggle("Slow events", isOn: $slow)
            Toggle("Dark appearance", isOn: $dark)
          }
          Text(scenario.guidance).font(.callout).fixedSize(horizontal: false, vertical: true)
          Text(
            "No downloads, helper, disk writes, shutdown, or real credentials. Scenario and speed changes reset the simulated session."
          )
          .font(.caption)
        }
        .padding(16)
        .background(OmarchyTheme.card)
        Divider()
        OnePageInstallerView(
          environment: environment, channel: channel,
          onChannelAvailability: { canChangeChannel = $0 }
        )
        .id(generation)
      }
      .preferredColorScheme(dark ? .dark : .light)
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
