import SwiftUI

// Notification used to request opening the Settings window from
// places where @Environment(\.openWindow) isn't available (e.g. .commands).
extension Notification.Name {
    static let openSettings = Notification.Name("TBOpenSettings")
}

@main
struct TouchBridgeMenuApp: App {
    @StateObject private var appState = MenuBarState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Menu bar icon
        MenuBarExtra {
            MenuBarView(state: appState)
                .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
                    openSettingsWindow()
                }
        } label: {
            // SF Symbol with hierarchical rendering + foregroundStyle
            // adapts to light/dark mode automatically. Color indicates status.
            Image(systemName: "touchid")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(menuBarColor)
        }
        .menuBarExtraStyle(.window)
        .commands {
            // Replace the default app settings item with our own that opens
            // our WindowGroup-based settings window.  SwiftUI automatically
            // displays the keyboard shortcut next to the menu item.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

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
        WindowGroup("TouchBridge Settings", id: "settings") {
            SettingsWindowView(state: appState)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 720, height: 520)
    }

    /// Focus an existing settings window, or open a new one.
    private func openSettingsWindow() {
        for window in NSApplication.shared.windows {
            if window is NSPanel { continue }
            if window.toolbar == nil { continue }
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
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
