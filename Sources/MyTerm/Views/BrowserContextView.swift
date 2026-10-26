import AppKit
import MyTermCore
import MyTermPlatform
import SwiftUI

struct BrowserContextReview: Identifiable {
    let id = UUID()
    let capture: BrowserContextCapture
}

struct BrowserContextView: View {
    let model: AppModel
    let workspaceID: WorkspaceID
    let capture: BrowserContextCapture
    @State private var text: String
    @State private var targetID: TabID?
    @State private var includesScreenshot = true
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, workspaceID: WorkspaceID, capture: BrowserContextCapture) {
        self.model = model
        self.workspaceID = workspaceID
        self.capture = capture
        _text = State(initialValue: capture.draft())
        _targetID = State(initialValue: model.browserContextTargets(in: workspaceID).first?.id)
    }

    private var targets: [BrowserContextTerminalTarget] { model.browserContextTargets(in: workspaceID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Browser context").font(.title2)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Review page context and add your instruction before inserting it into a terminal.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                TextEditor(text: $text).font(.body.monospaced())
                    .frame(minWidth: 300, minHeight: 240)
                    .accessibilityLabel("Browser feedback draft")
                if let image = NSImage(data: capture.screenshotPNG) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 250, height: 240)
                        .accessibilityLabel("Captured visible page")
                }
            }
            Toggle("Include screenshot file reference", isOn: $includesScreenshot)
            Text("The screenshot is saved locally for up to 24 hours (cleaned on next capture or launch), and its path is inserted with the text. Your coding agent must read the image file; it is not automatically attached. No Return is added. Multiline insertion requires bracketed paste.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Destination terminal", selection: $targetID) {
                Text("Choose a terminal").tag(Optional<TabID>.none)
                ForEach(targets) { target in Text(target.title).tag(Optional(target.id)) }
            }
            if targets.isEmpty { Text("Open a terminal in this workspace to receive this context.").foregroundStyle(.secondary) }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Text("Capture covers the visible page and selected text only.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Insert into terminal") { insert() }
                    .disabled(targetID == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(minWidth: 650, minHeight: 430)
    }

    private func insert() {
        guard let target = targets.first(where: { $0.id == targetID }) else {
            errorMessage = "Choose an available terminal."
            return
        }
        do {
            try model.insertBrowserContext(text, screenshot: includesScreenshot ? capture.screenshotPNG : nil, target: target)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
