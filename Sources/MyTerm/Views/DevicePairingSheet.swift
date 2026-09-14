import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MyTermRemoteProtocol
import SwiftUI

/// Identifies the sheet by the port it is showing, so presenting it is one assignment.
struct PairingPort: Identifiable {
    let value: UInt16
    var id: UInt16 { value }
}

/// Shows the code a device scans to reach this Mac.
///
/// The code carries the standing pairing token, not a one-shot secret, so it stays valid until the
/// token is regenerated. That is why this sheet says so plainly and offers no countdown: a timer
/// here would imply an expiry the host does not enforce.
struct DevicePairingSheet: View {
    let port: UInt16
    let token: String
    /// The name this Mac advertises, so the device can find it again after its address changes.
    let serviceName: String
    /// The relay this Mac is reachable through, when reach from anywhere is on.
    let relay: RelayEndpoint?
    let onDone: () -> Void

    @State private var address: String? = LocalNetworkAddress.current()

    var body: some View {
        VStack(spacing: 16) {
            Text("Link a Device")
                .font(.title2.weight(.semibold))

            if let address, let url = LocalNetworkAddress.connectURL(host: address, port: port, token: token, serviceName: serviceName, relay: relay) {
                code(for: url)

                Text("Point the device's camera at this code.")
                    .font(.callout)

                LabeledContent("Address") {
                    Text("\(address):\(String(port))")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: 320)

                Text(relay == nil
                     ? "The device and this Mac must be on the same network. Anyone who scans this code can reach these terminals until you regenerate the token."
                     : "Scan on the same network as this Mac. The device can then reach it from anywhere through the relay. Anyone who scans this code can reach these terminals until you regenerate the token.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            } else {
                Label(
                    "This Mac has no address on a local network. Join a Wi-Fi network and open this again.",
                    systemImage: "wifi.slash"
                )
                .font(.callout)
                .frame(maxWidth: 320)
            }

            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .onAppear { address = LocalNetworkAddress.current() }
    }

    @ViewBuilder
    private func code(for url: URL) -> some View {
        if let image = Self.qrCode(for: url) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 220, height: 220)
                .accessibilityLabel("Pairing code for \(url.absoluteString)")
        } else {
            Text(url.absoluteString)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: 320)
        }
    }

    /// CoreImage emits the code at one module per pixel, so it is scaled up with no interpolation.
    /// Smoothing the edges is what makes a small code fail to scan.
    private static func qrCode(for url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        let scale = 12.0
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
