import SwiftUI

struct SettingsWindowView: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        TabView {
            GeneralSettingsView(state: state)
                .tabItem { Label("General", systemImage: "gear") }

            DevicesSettingsView(state: state)
                .tabItem { Label("Devices", systemImage: "iphone") }

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 420)
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
        Form {
            // MARK: - Service

            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.isDaemonRunning ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(state.isDaemonRunning ? "Running" : "Stopped")
                            .foregroundStyle(state.isDaemonRunning ? .primary : .secondary)
                    }
                }

                Toggle(isOn: Binding(
                    get: { state.isAutoLaunchEnabled },
                    set: { _ in state.toggleAutoLaunch() }
                )) {
                    Text("Launch daemon at login")
                }
                .toggleStyle(.switch)

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
            } header: {
                Text("Service")
            } footer: {
                Text("The daemon runs in the background and handles authentication requests from PAM.")
            }

            // MARK: - Authentication Surfaces

            Section {
                Toggle(isOn: $pendingSudo) {
                    Label("Use TouchBridge for sudo", systemImage: "terminal")
                }
                .toggleStyle(.switch)
                .disabled(state.isInstalling)

                Toggle(isOn: $pendingScreensaver) {
                    Label("Use TouchBridge for screen saver unlock", systemImage: "lock.open")
                }
                .toggleStyle(.switch)
                .disabled(state.isInstalling)

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
            } header: {
                Text("Authentication Surfaces")
            } footer: {
                if hasPendingChanges {
                    Text("Click Apply to confirm. You will be asked for your administrator password to modify PAM configuration.")
                } else {
                    Text("Choose which authentication prompts should offer TouchBridge. Your password always remains available as a fallback.")
                }
            }

            // MARK: - Uninstall

            Section {
                Button("Uninstall TouchBridge…", role: .destructive) {
                    showUninstallAlert = true
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Sync local state from actual state when the view appears.
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
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "touchid")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("TouchBridge")
                .font(.title2.bold())

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Approve authentication on your Mac\nusing a nearby phone or watch.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Spacer()

            Text("MIT License")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}
