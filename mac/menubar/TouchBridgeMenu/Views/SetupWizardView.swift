import SwiftUI

/// First-launch install window — single clean flow, not a multi-step wizard.
struct SetupWizardView: View {
    @ObservedObject var state: MenuBarState
    @State private var patchSudo = true
    @State private var patchScreensaver = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "touchid")
                    .font(.system(size: 56))
                    .foregroundColor(.accentColor)
                Text("TouchBridge")
                    .font(.largeTitle.bold())
                Text("Approve authentication on your Mac\nusing your phone or watch.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)
            .padding(.bottom, 32)

            // Install state
            VStack(spacing: 20) {
                if state.isInstalling {
                    ProgressView()
                        .scaleEffect(1.3)
                    Text("Installing…")
                        .font(.headline)
                    Text("You may be prompted to approve TouchBridge in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if state.isInstalled {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)
                        Text("TouchBridge is installed")
                            .font(.headline)
                        Text("Pair a device from the menu bar to get started.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    installOptions
                    installButton
                }

                if let msg = state.installMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(msg.contains("fail") ? .red : .green)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)

            Spacer()

            // Footer
            HStack {
                Spacer()
                if state.isInstalled {
                    Button("Done") {
                        NSApplication.shared.keyWindow?.close()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        .frame(width: 520, height: 560)
    }

    private var installOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Authentication surfaces:")
                .font(.subheadline.bold())

            Toggle(isOn: $patchSudo) {
                Label("sudo (recommended)", systemImage: "terminal")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $patchScreensaver) {
                Label("Screensaver unlock", systemImage: "lock.open")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text("Your admin password will be required. PAM configs are backed up before modification.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial)
        .cornerRadius(10)
    }

    private var installButton: some View {
        Button {
            Task {
                await state.installSystem(
                    patchSudo: patchSudo,
                    patchScreensaver: patchScreensaver
                )
            }
        } label: {
            Label("Install TouchBridge", systemImage: "arrow.down.circle.fill")
                .font(.headline)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}
