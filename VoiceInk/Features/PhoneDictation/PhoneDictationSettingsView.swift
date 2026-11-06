import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings section for using this Mac as the dictation engine of a paired phone.
struct PhoneDictationSettingsSection: View {
    @ObservedObject var controller: PhoneDictationController
    @State private var showRegenerateConfirmation = false
    @State private var copiedToken = false

    var body: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { controller.isEnabled },
                    set: { controller.setEnabled($0) }
                )
            ) {
                HStack(spacing: 4) {
                    Text("Allow Phone Dictation")
                    InfoTip(
                        "Runs a local server so a paired phone can send recordings and get back text from this Mac's transcription model, dictionary, replacements and AI cleanup."
                    )
                }
            }

            if controller.isEnabled {
                LabeledContent("Status") {
                    statusText
                }

                if let payload = controller.pairingPayload, let image = Self.qrImage(for: payload) {
                    LabeledContent("Pairing Code") {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 180, height: 180)
                            .accessibilityLabel("Phone pairing QR code")
                    }
                }

                LabeledContent("Addresses") {
                    VStack(alignment: .trailing, spacing: 4) {
                        if controller.addresses.isEmpty {
                            Text("No network connection")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(controller.addresses) { address in
                            HStack(spacing: 6) {
                                Text(verbatim: "\(address.address):\(portText)")
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                                Text(address.kind == .tailscale ? "Tailscale" : "LAN")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Refresh") {
                            controller.refreshAddresses()
                        }
                        .controlSize(.small)
                    }
                }

                LabeledContent("Pairing Token") {
                    HStack {
                        Button(copiedToken ? "Copied" : "Copy") {
                            guard let token = controller.token else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(token, forType: .string)
                            copiedToken = true
                        }
                        .disabled(controller.token == nil)
                        Button("Regenerate…") {
                            showRegenerateConfirmation = true
                        }
                    }
                }

                if let tokenError = controller.tokenError {
                    Text(tokenError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Phone Dictation")
        } footer: {
            Text(
                "Scan the code with the VoiceInk Android app. Regenerating the token unpairs every phone."
            )
        }
        .onAppear {
            controller.refreshAddresses()
        }
        .onChange(of: controller.token) { _, _ in
            copiedToken = false
        }
        .confirmationDialog(
            "Regenerate the pairing token?",
            isPresented: $showRegenerateConfirmation
        ) {
            Button("Regenerate", role: .destructive) {
                controller.regenerateToken()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Phones paired with the current token stop working until you scan the new code.")
        }
    }

    private var portText: String {
        if case .running(let port) = controller.serverState {
            return String(port)
        }
        return String(controller.port)
    }

    @ViewBuilder
    private var statusText: some View {
        switch controller.serverState {
        case .stopped:
            Text("Stopped").foregroundStyle(.secondary)
        case .starting:
            Text("Starting…").foregroundStyle(.secondary)
        case .running(let port):
            Text("Listening on port \(String(port))").foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    static func qrImage(for payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
