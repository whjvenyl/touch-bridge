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
        .frame(width: 500, height: 380)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        Form {
            Section("Daemon") {
                LabeledContent("Status") {
                    HStack {
                        Circle()
                            .fill(state.isDaemonRunning ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(state.isDaemonRunning ? "Running" : "Stopped")
                    }
                }

                LabeledContent("Socket") {
                    Text(state.isDaemonRunning ? "Available" : "Unavailable")
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: Binding(
                    get: { state.isAutoLaunchEnabled },
                    set: { _ in state.toggleAutoLaunch() }
                )) {
                    Text("Launch daemon at login")
                }

                HStack {
                    if state.isDaemonRunning {
                        Button("Stop Daemon") { state.stopDaemon() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Start Daemon") { state.startDaemon() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            Section("BLE") {
                if let status = state.status {
                    LabeledContent("Advertising") {
                        Text(status.isAdvertising ? "Yes" : "No")
                            .foregroundStyle(status.isAdvertising ? .green : .secondary)
                    }
                    LabeledContent("Connected centrals") {
                        Text("\(status.connectedDevices.count)")
                    }
                } else {
                    Text("Daemon not connected")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Statistics") {
                LabeledContent("Successful auths") {
                    Text("\(state.authCount)")
                }
            }

            Section {
                Button("Uninstall TouchBridge…", role: .destructive) {
                    let alert = NSAlert()
                    alert.messageText = "Uninstall TouchBridge?"
                    alert.informativeText = "This will remove the daemon, PAM module, and restore your original sudo config."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Uninstall")
                    alert.addButton(withTitle: "Cancel")

                    if alert.runModal() == .alertFirstButtonReturn {
                        runUninstall()
                    }
                }
            }
        }
        .padding()
    }

    private func runUninstall() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"/bin/bash /usr/local/share/touchbridge/uninstall.sh\" with administrator privileges"
        ]
        try? process.run()
    }
}

struct DevicesSettingsView: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        VStack(spacing: 16) {
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
                            openPairingWindow()
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
                            openPairingWindow()
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
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
        .padding()
    }

    private func openPairingWindow() {
        // Open the pairing window via NSApp
        if let url = URL(string: "touchbridge://pairing") {
            NSWorkspace.shared.open(url)
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

            Text("Use your phone's fingerprint to\nauthenticate on any Mac.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Spacer()

            Link("GitHub", destination: URL(string: "https://github.com/HMAKT99/UnTouchID")!)
                .font(.caption)

            Text("MIT License")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}
