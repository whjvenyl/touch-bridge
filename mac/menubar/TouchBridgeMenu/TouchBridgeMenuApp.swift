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

        // Settings window (using WindowGroup instead of Settings so it works
        // in a menu bar-only app where there's no app menu for showSettingsWindow:)
        WindowGroup("TouchBridge Settings", id: "settings") {
            SettingsWindowView(state: appState)
        }
        .windowResizability(.contentSize)
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
