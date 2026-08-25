import SwiftUI

@main
struct TouchBridgeMenuApp: App {
    @StateObject private var appState = MenuBarState()

    var body: some Scene {
        // Menu bar icon
        MenuBarExtra {
            MenuBarView(state: appState)
        } label: {
            Image(systemName: "touchid")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(menuBarColor)
        }
        .menuBarExtraStyle(.window)

        // Setup wizard window (shown on first launch)
        WindowGroup("TouchBridge Setup", id: "setup") {
            SetupWizardView(state: appState)
        }
        .windowResizability(.contentSize)

        // Pairing window
        WindowGroup("TouchBridge Pairing", id: "pairing") {
            PairingView(state: appState)
        }
        .windowResizability(.contentSize)

        // Settings window
        Settings {
            SettingsWindowView(state: appState)
        }
    }

    private var menuBarColor: Color {
        if !appState.isInstalled { return .red }
        if !appState.isDaemonRunning { return .orange }
        if let status = appState.status,
           status.pairedDevices.contains(where: { $0.isConnected }) {
            return .green
        }
        return .secondary
    }
}
