import SwiftUI

struct MenuBarView: View {
    @ObservedObject var state: MenuBarState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !state.isInstalled {
                notInstalledView
            } else {
                installedView
            }
        }
        .frame(width: 320)
    }

    // MARK: - Not installed

    private var notInstalledView: some View {
        VStack(spacing: 12) {
            Image(systemName: "touchid")
                .font(.title2)
                .foregroundStyle(.red)
            Text("TouchBridge")
                .font(.headline)
            Text("Not installed yet. Install to start approving authentication from your phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if state.isInstalling {
                ProgressView()
                    .controlSize(.small)
                Text("Installing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Install TouchBridge") {
                    Task { await state.installSystem() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            if let msg = state.installMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(msg.contains("fail") ? .red : .green)
                    .multilineTextAlignment(.center)
            }

            Divider()
            quitButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Installed

    private var installedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            daemonSection
            if let status = state.status, !status.pairedDevices.isEmpty {
                Divider()
                pairedDevicesSection(status.pairedDevices)
            }
            if !state.recentEvents.isEmpty {
                Divider()
                recentActivitySection
            }
            Divider()
            actionsSection
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "touchid")
                .font(.title2)
                .foregroundStyle(headerColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("TouchBridge")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var daemonSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(state.isDaemonRunning ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(state.isDaemonRunning ? "Daemon running" : "Daemon stopped")
                    .font(.subheadline)
                Spacer()
                if state.isDaemonRunning {
                    Button("Stop") { state.stopDaemon() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("Start") { state.startDaemon() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if let status = state.status {
                HStack {
                    Image(systemName: status.isAdvertising ? "antenna.radiowaves.left.and.right" : "antenna.slash")
                        .font(.caption)
                        .foregroundStyle(status.isAdvertising ? .green : .secondary)
                    Text(status.isAdvertising ? "Advertising" : "Not advertising")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if status.isPairingActive {
                        Label("Pairing…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func linkQualityLabel(_ quality: String) -> String {
        switch quality {
        case "good": return "Good"
        case "fair": return "Fair"
        case "poor": return "Poor"
        default: return ""
        }
    }

    private func linkQualityColor(_ quality: String) -> Color {
        switch quality {
        case "good": return .green
        case "fair": return .yellow
        case "poor": return .orange
        default: return .secondary
        }
    }

    private func pairedDevicesSection(_ devices: [DaemonClient.DaemonStatus.PairedDeviceInfo]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Paired Devices (\(devices.count))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 2)

            ForEach(devices) { device in
                HStack {
                    Circle()
                        .fill(device.isConnected ? .green : .secondary)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.displayName)
                            .font(.subheadline)
                        HStack(spacing: 6) {
                            Text(device.isConnected ? "Connected" : "Disconnected")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if device.isConnected {
                                Text("•")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(linkQualityLabel(device.linkQuality))
                                    .font(.caption2)
                                    .foregroundStyle(linkQualityColor(device.linkQuality))
                            }
                            if device.deviceType != "unspecified" {
                                Text("•")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(device.deviceType.capitalized)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { device.enabled },
                        set: { newVal in
                            state.setDeviceEnabled(deviceID: device.deviceID, enabled: newVal)
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    Button {
                        state.unpairDevice(deviceID: device.deviceID)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Unpair \(device.displayName)")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            Button {
                state.startPairing()
                openWindow(id: "pairing")
            } label: {
                Label("Pair New Device", systemImage: "plus.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Activity")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(state.recentEvents.prefix(5)) { event in
                HStack {
                    Image(systemName: event.result == "VERIFIED" ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(event.result == "VERIFIED" ? .green : .red)
                        .font(.caption)
                    Text(event.surface)
                        .font(.caption)
                    Spacer()
                    Text(formatTime(event.ts))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.status == nil && state.isDaemonRunning {
                Button {
                    state.startPairing()
                    openWindow(id: "pairing")
                } label: {
                    Label("Pair New Device", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            Toggle(isOn: Binding(
                get: { state.isAutoLaunchEnabled },
                set: { _ in state.toggleAutoLaunch() }
            )) {
                Label("Launch at Login", systemImage: "power")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)

            Button {
                openWindow(id: "settings")
            } label: {
                Label("Settings…", systemImage: "gear")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()

            quitButton
        }
    }

    private var quitButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Text("Quit TouchBridge")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private var headerColor: Color {
        if !state.isInstalled { return .red }
        if !state.isDaemonRunning { return .orange }
        if let status = state.status, status.pairedDevices.contains(where: { $0.isConnected }) {
            return .green
        }
        return .secondary
    }

    private var statusText: String {
        if !state.isInstalled { return "Not installed" }
        if !state.isDaemonRunning { return "Daemon stopped" }
        if let status = state.status {
            if status.pairedDevices.isEmpty { return "No devices paired" }
            let connected = status.pairedDevices.filter(\.isConnected).count
            if connected > 0 { return "Ready — \(connected) device(s) connected" }
            return "Waiting for device…"
        }
        return "Connecting…"
    }

    private func formatTime(_ iso: String) -> String {
        let parts = iso.split(separator: "T")
        if parts.count == 2 {
            return String(parts[1].prefix(5))
        }
        return iso
    }
}
