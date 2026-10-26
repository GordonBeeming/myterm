import MyTermCore
import SwiftUI

struct CompanionBrowserCapture: Identifiable {
    let id = UUID()
    let url: String
    let title: String
    let selectedText: String
    let screenshot: Data?
    let notes: [String]

    func appending(instructions: String, to existing: String,
                   capturedConnection: SavedConnectionID, currentConnection: SavedConnectionID?) throws -> String {
        guard capturedConnection == currentConnection else { throw BrowserContextHandoffError.hostChanged }
        let addition = context(instructions: instructions)
        let combined = existing.isEmpty ? addition : existing + "\n\n" + addition
        guard combined.utf8.count <= TerminalComposerDraft.maximumUTF8Bytes else {
            throw BrowserContextHandoffError.tooLong
        }
        return combined
    }

    func context(instructions: String) -> String {
        var parts = [instructions.trimmingCharacters(in: .whitespacesAndNewlines),
                     "Browser page: \(title)", "URL: \(url)"]
        if !selectedText.isEmpty { parts.append("Selected page text (context):\n\(selectedText)") }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

enum BrowserContextHandoffError: LocalizedError {
    case hostChanged, tooLong
    var errorDescription: String? {
        switch self {
        case .hostChanged: "The selected Mac changed. Open the original Mac before adding this capture."
        case .tooLong: "The combined draft is too long. Shorten the instruction or existing draft."
        }
    }
}

struct BrowserContextHandoffView: View {
    let scene: SceneModel
    let browser: BrowserRoute
    let capture: CompanionBrowserCapture
    let openComposer: (TerminalRoute) -> Void
    @State private var instructions = ""
    @State private var destinationID: UUID?
    @State private var status: String?
    @State private var isPasting = false
    @Environment(\.dismiss) private var dismiss

    private var destinations: [TerminalRoute] {
        guard let workspace = scene.projection?.workspaces.first(where: { $0.id.rawValue == browser.workspaceID }) else { return [] }
        return workspace.groups.flatMap { group in
            group.tabs.compactMap { tab in
                guard let session = tab.terminalSessionID else { return nil }
                return TerminalRoute(connectionID: browser.connectionID, workspaceID: browser.workspaceID,
                    groupID: group.id.rawValue, tabID: tab.id.rawValue, sessionID: session.rawValue, title: tab.title)
            }
        }
    }
    private var destination: TerminalRoute? { destinations.first { $0.tabID == destinationID } }
    private var canPaste: Bool {
        guard let destination, let surface = scene.terminalStates[destination.id] else { return false }
        return surface.ownsControl && !surface.isAwaitingCheckpoint && scene.connectionPhase == .online
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Captured page") {
                    Text(capture.title)
                    Text(capture.url).font(.caption).textSelection(.enabled)
                    if !capture.selectedText.isEmpty {
                        Text(capture.selectedText).font(.caption).textSelection(.enabled)
                    }
                    ForEach(capture.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Instruction") {
                    TextEditor(text: $instructions).frame(minHeight: 110)
                        .accessibilityLabel("Browser context instruction")
                }
                Section("Destination terminal") {
                    Picker("Terminal", selection: $destinationID) {
                        Text("Choose a terminal").tag(Optional<UUID>.none)
                        ForEach(destinations) { route in Text(route.title).tag(Optional(route.tabID)) }
                    }
                    if destinations.isEmpty { Text("Open a terminal in this workspace first.").foregroundStyle(.secondary) }
                    Button("Append context to Compose") { appendContext() }
                        .disabled(destination == nil || isPasting)
                    Text("Adds URL, selected text and your instruction to the existing draft for review. Nothing is sent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let screenshot = capture.screenshot, let image = UIImage(data: screenshot) {
                    Section("Screenshot") {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 230)
                        Button(isPasting ? "Pasting screenshot…" : "Paste screenshot to terminal") {
                            Task { await pasteScreenshot(screenshot) }
                        }
                        .disabled(!canPaste || isPasting)
                        Text("A separate action using the Mac clipboard and paste shortcut. Requires control of an open destination terminal. The agent must support pasted images; no Return is sent.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !canPaste {
                            Text("Open this terminal and acquire control before using screenshot paste.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let status { Section { Text(status).font(.footnote).textSelection(.enabled) } }
            }
            .navigationTitle("Browser context")
            .toolbar { Button("Done") { dismiss() }.disabled(isPasting) }
            .onAppear { if destinationID == nil { destinationID = destinations.first?.tabID } }
        }
    }

    private func appendContext() {
        guard let destination else { status = "Choose an available destination terminal."; return }
        let draft = scene.composerDraft(for: destination)
        guard !draft.isSending else { status = "Wait for the current insertion to finish."; return }
        do {
            draft.text = try capture.appending(instructions: instructions, to: draft.text,
                capturedConnection: browser.connectionID, currentConnection: scene.selectedConnectionID)
        } catch {
            status = error.localizedDescription
            return
        }
        openComposer(destination)
        dismiss()
    }

    private func pasteScreenshot(_ data: Data) async {
        guard let destination, canPaste else { return }
        isPasting = true
        defer { isPasting = false }
        do {
            try await scene.pasteImage(data, route: destination)
            status = "Screenshot pasted into \(destination.title). Check the terminal to confirm the agent accepted it."
        } catch {
            status = "Screenshot paste was not confirmed. Check the terminal before trying again: \(error.localizedDescription)"
        }
    }
}
