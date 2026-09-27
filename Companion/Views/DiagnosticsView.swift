import SwiftUI

/// Shows what the connection has been doing and lets the user send it in.
///
/// Collection is off until asked for, and nothing leaves the device until the user shares it.
struct DiagnosticsView: View {
    @AppStorage("collectDiagnostics") private var collectDiagnostics = false
    @State private var entries: [DiagnosticsEntry] = []
    @State private var exportURL: URL?

    var body: some View {
        List {
            Section {
                Toggle("Collect diagnostics", isOn: $collectDiagnostics)
                    .accessibilityIdentifier("collect-diagnostics")
            } footer: {
                Text("Records connections, reconnects, terminal attachments and control changes on "
                     + "this device. It never records what a terminal shows or anything you type.")
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
