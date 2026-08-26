import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Pairing window — shows QR code and waits for a companion to pair.
struct PairingView: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "qrcode")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
                Text("Pair a Device")
                    .font(.title2.bold())
                Text("Scan this QR code with the TouchBridge app on your phone or watch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // QR code, loading, success, or error
            if state.pairingSucceeded {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("Pairing Successful")
                        .font(.headline)
                    if let device = state.status?.pairedDevices.last {
                        Text("\(device.displayName) is now paired and ready.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Your device is now paired and ready.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 220, height: 220)
            } else if let qrData = state.pairingQRData,
               let qrImage = generateQRCode(from: qrData) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(8)
                    .background(.regularMaterial)
                    .cornerRadius(12)
            } else if state.isPairing {
                ProgressView("Generating pairing code…")
                    .frame(width: 220, height: 220)
            } else if let error = state.pairingError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    Text("Pairing failed")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(width: 220, height: 220)
            }

            // Pairing data (manual entry fallback) — hidden on success
            if let qrData = state.pairingQRData, !state.pairingSucceeded {
                DisclosureGroup("Manual Pairing Data") {
                    Text(qrData)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.regularMaterial)
                        .cornerRadius(8)
                }
                .font(.caption)
            }

            // Status
            if state.isPairing {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for device to connect…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Buttons
            HStack {
                if state.isPairing {
                    Button("Cancel") {
                        state.cancelPairing()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Close") {
                        NSApplication.shared.keyWindow?.close()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
                if !state.isPairing && !state.pairingSucceeded {
                    Button("Try Again") {
                        state.startPairing()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 480, height: 600)
        .onAppear {
            if !state.isPairing && state.pairingQRData == nil && !state.pairingSucceeded {
                state.startPairing()
            }
        }
        .onDisappear {
            if state.isPairing {
                state.cancelPairing()
            }
        }
        .onChange(of: state.pairingSucceeded) { succeeded in
            // Auto-close the pairing window 3 seconds after success,
            // giving the user time to see the confirmation.
            if succeeded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    NSApplication.shared.keyWindow?.close()
                }
            }
        }
    }

    /// Generate a QR code NSImage from a string.
    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }

        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
