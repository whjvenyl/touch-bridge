import SwiftUI

// MARK: - Settings navigation

/// Identifies a settings pane in the sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case devices
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .devices: "Devices"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .devices: "iphone"
        case .about: "info.circle"
        }
    }
}

// MARK: - Root settings view

struct SettingsWindowView: View {
    @ObservedObject var state: MenuBarState
    @State private var selection: SettingsPane? = .general

    private var allPanes: [SettingsPane] { SettingsPane.allCases }
    private var currentIndex: Int? { allPanes.firstIndex(of: selection ?? .general) }
    private var isFirst: Bool { currentIndex == 0 }
    private var isLast: Bool { currentIndex == allPanes.count - 1 }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(allPanes) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .tag(pane)
                }
            }
            .scrollDisabled(true)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detailPane
                .id(selection) // Force view recreation on pane switch
        }
        .navigationSplitViewStyle(.balanced)
        .removeSidebarToggle()
        .navigationTitle(selection?.title ?? "Settings")
        .toolbar {
            // Back/Forward navigation between settings panes
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button {
                        if let idx = currentIndex, idx > 0 {
                            selection = allPanes[idx - 1]
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .disabled(isFirst)

                    Button {
                        if let idx = currentIndex, idx < allPanes.count - 1 {
                            selection = allPanes[idx + 1]
                        }
                    } label: {
                        Label("Forward", systemImage: "chevron.right")
                    }
                    .disabled(isLast)
                }
                .controlGroupStyle(.navigation)
            }
        }
        .frame(minWidth: 650, minHeight: 500)
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selection {
        case .general:
            GeneralSettingsView(state: state)
        case .devices:
            DevicesSettingsView(state: state)
        case .about:
            AboutView()
        case nil:
            GeneralSettingsView(state: state)
        }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var state: MenuBarState
    @State private var showUninstallAlert = false
    @State private var showApplyAlert = false

    // Local pending preferences — the user edits these freely, and they
    // only become live when "Apply" is clicked. This avoids triggering a
    // privileged operation on every toggle flip.
    @State private var pendingSudo: Bool = false
    @State private var pendingScreensaver: Bool = false

    /// True when the local pending state differs from what's actually applied.
    private var hasPendingChanges: Bool {
        pendingSudo != state.sudoEnabled || pendingScreensaver != state.screensaverEnabled
    }

    var body: some View {
        TBForm(spacing: 16) {
            // MARK: - Service

            TBSection("Service") {
                TBLabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.isDaemonRunning ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(state.isDaemonRunning ? "Running" : "Stopped")
                            .foregroundStyle(state.isDaemonRunning ? .primary : .secondary)
                    }
                }

                TBLabeledContent {
                    Toggle(isOn: Binding(
                        get: { state.isAutoLaunchEnabled },
                        set: { _ in state.toggleAutoLaunch() }
                    )) {
                        Text("Launch daemon at login")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                } label: {
                    Text("Launch daemon at login")
                }

                HStack {
                    if state.isDaemonRunning {
                        Button("Stop Daemon", role: .destructive) {
                            state.stopDaemon()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("Start Daemon") {
                            state.startDaemon()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } footer: {
                Text("The daemon runs in the background and handles authentication requests from PAM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Authentication Surfaces

            TBSection("Authentication Surfaces") {
                TBLabeledContent {
                    Toggle(isOn: $pendingSudo) {
                        Label("Use TouchBridge for sudo", systemImage: "terminal")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(state.isInstalling)
                } label: {
                    Label("Use TouchBridge for sudo", systemImage: "terminal")
                }
                .annotation("Approve sudo prompts from your paired device instead of typing your password.")

                TBLabeledContent {
                    Toggle(isOn: $pendingScreensaver) {
                        Label("Use TouchBridge for screen saver unlock", systemImage: "lock.open")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(state.isInstalling)
                } label: {
                    Label("Use TouchBridge for screen saver unlock", systemImage: "lock.open")
                }
                .annotation("Unlock the screen saver by approving on your paired device.")

                if state.isInstalling {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Applying changes…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if hasPendingChanges {
                    HStack {
                        Button("Apply Changes") {
                            showApplyAlert = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("Revert") {
                            pendingSudo = state.sudoEnabled
                            pendingScreensaver = state.screensaverEnabled
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } footer: {
                if hasPendingChanges {
                    Text("Click Apply to confirm. You will be asked for your administrator password to modify PAM configuration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Your password always remains available as a fallback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - Uninstall

            TBSection {
                Button("Uninstall TouchBridge…", role: .destructive) {
                    showUninstallAlert = true
                }
            }
        }
        .onAppear {
            pendingSudo = state.sudoEnabled
            pendingScreensaver = state.screensaverEnabled
        }
        .onChange(of: state.sudoEnabled) { _, newValue in
            pendingSudo = newValue
        }
        .onChange(of: state.screensaverEnabled) { _, newValue in
            pendingScreensaver = newValue
        }
        .alert("Uninstall TouchBridge?", isPresented: $showUninstallAlert) {
            Button("Uninstall", role: .destructive) {
                Task { await state.uninstallSystem() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the daemon, PAM module, and restore your original PAM configs. Paired devices and logs are preserved.")
        }
        .alert("Apply Authentication Changes?", isPresented: $showApplyAlert) {
            Button("Apply", role: .destructive) {
                Task {
                    if pendingSudo != state.sudoEnabled {
                        await state.togglePAMSurface("sudo", enabled: pendingSudo)
                    }
                    if pendingScreensaver != state.screensaverEnabled {
                        await state.togglePAMSurface("screensaver", enabled: pendingScreensaver)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingSudo = state.sudoEnabled
                pendingScreensaver = state.screensaverEnabled
            }
        } message: {
            Text("Modifying PAM configuration requires administrator privileges. You will be prompted for your password.")
        }
    }
}

struct DevicesSettingsView: View {
    @ObservedObject var state: MenuBarState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if let status = state.status {
                if status.pairedDevices.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "iphone.slash")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("No paired devices")
                            .font(.headline)
                        Text("Pair your phone or watch to authenticate with biometrics.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button("Pair New Device") {
                            state.startPairing()
                            openWindow(id: "pairing")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(status.pairedDevices) { device in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.displayName)
                                        .font(.headline)
                                    Text("Paired \(formatDate(device.pairedAt))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(device.deviceID)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    HStack {
                                        Circle()
                                            .fill(device.isConnected ? .green : .secondary)
                                            .frame(width: 8, height: 8)
                                        Text(device.isConnected ? "Connected" : "Offline")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Button("Unpair", role: .destructive) {
                                        state.unpairDevice(deviceID: device.deviceID)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.inset)

                    HStack {
                        Button("Pair New Device") {
                            state.startPairing()
                            openWindow(id: "pairing")
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }

                // MARK: - Connection status

                Divider()

                Form {
                    Section {
                        LabeledContent("Advertising") {
                            Text(status.isAdvertising ? "Active" : "Inactive")
                                .foregroundStyle(status.isAdvertising ? .green : .secondary)
                        }

                        LabeledContent("Connected devices") {
                            Text("\(status.connectedDevices.count)")
                        }

                        LabeledContent("Successful authentications") {
                            Text("\(state.authCount)")
                        }
                    } header: {
                        Text("Connection")
                    } footer: {
                        Text("The daemon advertises over Bluetooth Low Energy so paired devices can reconnect automatically.")
                    }
                }
                .formStyle(.grouped)
                .frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Connecting to daemon…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct AboutView: View {
    @Environment(\.openURL) private var openURL

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var contributeURL: URL {
        URL(string: "https://github.com/cashcon57/UnTouchID")!
    }

    private var issuesURL: URL {
        contributeURL.appendingPathComponent("issues")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main content card
            VStack(spacing: 20) {
                Image(systemName: "touchid")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)

                VStack(spacing: 4) {
                    Text("TouchBridge")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(.primary)

                    Text("Version \(version)")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)

                    Text("Approve authentication on your Mac\nusing a nearby phone or watch.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(20)

            // Bottom bar
            HStack {
                Button("Quit TouchBridge") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Contribute") {
                    openURL(contributeURL)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

                Button("Report a Bug") {
                    openURL(issuesURL)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.quinary, in: Capsule(style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
