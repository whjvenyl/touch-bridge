import Combine
import SwiftUI

// Notification used to request opening the Settings window from
// places where @Environment(\.openWindow) isn't available (e.g. .commands).
extension Notification.Name {
    static let openSettings = Notification.Name("TBOpenSettings")
}

// MARK: - AppDelegate

/// Manages the `NSStatusItem` with dynamic content via `StatusItemManager`.
@MainActor
final class TouchBridgeAppDelegate: NSObject, NSApplicationDelegate {
    let statusItemManager = StatusItemManager()
    private var observers: Set<AnyCancellable> = []

    /// Reference to the SwiftUI app state, set from the App scene.
    weak var appState: MenuBarState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemManager.setup()
    }

    /// Called from SwiftUI to connect the menu bar popover content and
    /// start observing state changes.
    func connect(state: MenuBarState, popoverContent: AnyView) {
        self.appState = state
        statusItemManager.popoverContent = popoverContent

        // Observe state changes and update the status item
        state.$status.sink { [weak self] _ in
            self?.updateStatusItem(state: state)
        }.store(in: &observers)

        state.$isDaemonRunning.sink { [weak self] _ in
            self?.updateStatusItem(state: state)
        }.store(in: &observers)

        state.$isInstalled.sink { [weak self] _ in
            self?.updateStatusItem(state: state)
        }.store(in: &observers)

        state.$isAuthPending.sink { [weak self] _ in
            self?.updateStatusItem(state: state)
        }.store(in: &observers)

        updateStatusItem(state: state)
    }

    private func updateStatusItem(state: MenuBarState) {
        let connected = state.status?.pairedDevices.filter(\.isConnected).count ?? 0
        statusItemManager.update(
            isInstalled: state.isInstalled,
            isDaemonRunning: state.isDaemonRunning,
            connectedDevices: connected,
            isAuthPending: state.isAuthPending
        )
    }
}

// MARK: - App

@main
struct TouchBridgeMenuApp: App {
    @StateObject private var appState = MenuBarState()
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(TouchBridgeAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Hidden launch window that connects SwiftUI state to the AppKit
        // status item. Opens at launch, configures the status item, then
        // closes itself. Never visible to the user.
        WindowGroup(id: "launch-bridge") {
            LaunchBridgeView(state: appState, appDelegate: appDelegate) {
                openWindow(id: "setup")
            }
        }
        .windowResizability(.contentSize)

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
        .commands {
            // Replace the default app settings item with our own that opens
            // our WindowGroup-based settings window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // Replace the default Quit item
            CommandGroup(replacing: .appTermination) {
                Button("Quit TouchBridge") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

// MARK: - Launch bridge view

/// Invisible view that connects SwiftUI state to the `StatusItemManager`
/// on launch, then closes its own window.
private struct LaunchBridgeView: View {
    @ObservedObject var state: MenuBarState
    let appDelegate: TouchBridgeAppDelegate
    let onFirstLaunch: () -> Void
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                // Connect the status item to SwiftUI state
                let popoverContent = AnyView(
                    MenuBarView(state: state)
                        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
                            appDelegate.statusItemManager.closePopover()
                            NSApplication.shared.activate(ignoringOtherApps: true)
                            let hasSettings = NSApplication.shared.windows.contains { window in
                                !(window is NSPanel) && window.toolbar != nil
                            }
                            if !hasSettings {
                                openWindow(id: "settings")
                            } else {
                                for window in NSApplication.shared.windows {
                                    if !(window is NSPanel) && window.toolbar != nil {
                                        window.makeKeyAndOrderFront(nil)
                                        break
                                    }
                                }
                            }
                        }
                )

                appDelegate.connect(state: state, popoverContent: popoverContent)

                // Show setup wizard on first launch
                if !state.isInstalled {
                    onFirstLaunch()
                }

                // Close this invisible window
                dismissWindow(id: "launch-bridge")
            }
    }
}
