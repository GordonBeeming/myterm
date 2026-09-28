import SwiftUI

/// Shows what the connection has been doing and lets the user send it in.
///
/// Collection is off until asked for, and nothing leaves the device until the user shares it.
struct DiagnosticsView: View {
    let scene: SceneModel
    @AppStorage("collectDiagnostics") private var collectDiagnostics = false
    @AppStorage("sendDiagnosticsToMac") private var sendDiagnosticsToMac = false
    @State private var entries: [DiagnosticsEntry] = []
    @State private var exportURL: URL?
    @State private var isSending = false
    @State private var uploadOutcome: DiagnosticsUploadOutcome?

    var body: some View {
        List {
            Section {
                Toggle("Collect diagnostics", isOn: $collectDiagnostics)
                    .accessibilityIdentifier("collect-diagnostics")
                Toggle("Send to Mac", isOn: $sendDiagnosticsToMac)
                    .accessibilityIdentifier("send-diagnostics-to-mac")
                    .disabled(!collectDiagnostics)
                if collectDiagnostics && sendDiagnosticsToMac {
                    Button {
                        Task {
                            isSending = true
                            uploadOutcome = await scene.uploadDiagnostics()
                            isSending = false
                            await reload()
                        }
                    } label: {
                        HStack {
                            Text("Send now")
                            if isSending {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(isSending)
                    .accessibilityIdentifier("send-diagnostics-now")
                    if let uploadOutcome {
                        Text(uploadOutcome.message)
                            .font(.footnote)
                            .foregroundStyle(uploadOutcome.isFailure ? AnyShapeStyle(.red)
                                                                     : AnyShapeStyle(.secondary))
                            .accessibilityIdentifier("send-diagnostics-status")
                    }
                }
            } footer: {
                Text("Records connections, reconnects, terminal attachments and control changes on "
                     + "this device. It never records what a terminal shows or anything you type. "
                     + "Sending to the Mac files them beside its own data, where they are easier to "
                     + "read than on this device.")
            }

            if !entries.isEmpty {
                Section("Recent") {
                    ForEach(entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message)
                                .font(.callout)
                            Text(entry.line)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            } else {
                Section {
                    ContentUnavailableView("Nothing recorded yet", systemImage: "waveform.path",
                                           description: Text(collectDiagnostics
                                               ? "Events appear here as the app connects and reconnects."
                                               : "Turn on Collect diagnostics to start recording."))
                }
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Share", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("share-diagnostics")
                }
                Button("Clear", systemImage: "trash") {
                    Task {
                        await DiagnosticsLog.shared.clear()
                        // The export sits in a shared temporary directory, so clearing has to take
                        // it too rather than leave the entries readable after they are gone.
                        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
                        exportURL = nil
                        await reload()
                    }
                }
                .accessibilityIdentifier("clear-diagnostics")
            }
        }
        .task { await reload() }
        .onChange(of: collectDiagnostics) { _, enabled in
            Task {
                await DiagnosticsLog.shared.setEnabled(enabled)
                await reload()
            }
        }
        .refreshable { await reload() }
    }

    private func reload() async {
        entries = await DiagnosticsLog.shared.recent(limit: 200)
        exportURL = await writeExport()
    }

    /// Written to a file so the share sheet offers it as an attachment rather than a wall of text.
    private func writeExport() async -> URL? {
        let text = await DiagnosticsLog.shared.exportText()
        guard !text.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "myterm-diagnostics.txt", directoryHint: .notDirectory)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
