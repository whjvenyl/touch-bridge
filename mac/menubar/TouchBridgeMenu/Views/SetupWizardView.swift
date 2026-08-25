import SwiftUI

struct SetupWizardView: View {
    @ObservedObject var state: MenuBarState
    @State private var currentStep = 0
    @State private var installOutput = ""
    @State private var isInstalling = false
    @State private var installComplete = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "touchid")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                Text("TouchBridge Setup")
                    .font(.title.bold())
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            // Step indicator
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.bottom, 24)

            // Content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: installStep
                case 2: pairStep
                case 3: doneStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)

            Spacer()

            // Navigation
            HStack {
                if currentStep > 0 && currentStep < 3 {
                    Button("Back") { currentStep -= 1 }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if currentStep < 3 {
                    Button(currentStep == 0 ? "Get Started" : "Next") {
                        if currentStep == 1 && !installComplete {
                            runInstall()
                        } else {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(currentStep == 1 && isInstalling)
                } else {
                    Button("Done") {
                        NSApplication.shared.keyWindow?.close()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Text("Use your phone's fingerprint to\nauthenticate on your Mac.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "lock.shield", text: "Authenticate sudo with Face ID or fingerprint")
                FeatureRow(icon: "display", text: "Unlock screensaver without typing password")
                FeatureRow(icon: "iphone", text: "Works with iPhone, Android, Apple Watch, Wear OS")
                FeatureRow(icon: "key", text: "No $199 Magic Keyboard needed")
            }
        }
    }

    private var installStep: some View {
        VStack(spacing: 16) {
            if isInstalling {
                ProgressView()
                    .scaleEffect(1.5)
                    .padding()
                Text("Installing TouchBridge...")
                    .font(.headline)
                Text("This will ask for your admin password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if installComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("Installation Complete")
                    .font(.headline)
                Text("Daemon, PAM module, and LaunchAgent installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                Text("Install TouchBridge")
                    .font(.headline)
                Text("This will install the daemon and PAM module.\nYour admin password will be required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 4) {
                    Text("What gets installed:")
                        .font(.caption.bold())
                    Text("• touchbridge daemon → /usr/local/bin/")
                        .font(.caption)
                    Text("• PAM module → /usr/local/lib/pam/")
                        .font(.caption)
                    Text("• LaunchAgent (auto-start on login)")
                        .font(.caption)
                    Text("• sudo PAM hook (with backup)")
                        .font(.caption)
                }
                .padding()
                .background(.regularMaterial)
                .cornerRadius(8)
            }
        }
    }

    private var pairStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Pair Your Device")
                .font(.headline)

            Text("Open the TouchBridge app on your phone or watch, then scan the QR code or enter the pairing data.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Show pairing status
            if state.isPairing {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for device to connect…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let status = state.status, !status.pairedDevices.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                Text("Paired with \(status.pairedDevices.count) device(s)!")
                    .font(.subheadline)
            } else {
                Button("Start Pairing") {
                    state.startPairing()
                    openPairingWindow()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.headline)

            Text("TouchBridge is running in your menu bar.\nTry it out:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Image(systemName: "terminal")
                    .foregroundColor(.accentColor)
                Text("sudo echo 'TouchBridge works!'")
                    .font(.system(.caption, design: .monospaced))
            }
            .padding()
            .background(.regularMaterial)
            .cornerRadius(8)
        }
    }

    // MARK: - Actions

    private func runInstall() {
        isInstalling = true
        Task {
            await state.installSystem()
            await MainActor.run {
                isInstalling = false
                installComplete = state.isInstalled
                if installComplete { currentStep = 2 }
            }
        }
    }

    private func openPairingWindow() {
        if let url = URL(string: "touchbridge://pairing") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
        }
    }
}
