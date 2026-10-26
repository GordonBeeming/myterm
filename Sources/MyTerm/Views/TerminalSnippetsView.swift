import MyTermCore
import SwiftUI

/// Captured by AppModel when presentation starts, rather than by a recreatable View initializer.
struct TerminalSnippetDestination: Equatable {
    let workspaceID: UUID
    let sessionID: TerminalSessionID?
    let title: String

    @MainActor
    init(model: AppModel) {
        workspaceID = model.selectedWorkspace.id.rawValue
        sessionID = model.selectedTab?.terminalSession?.id
        title = model.selectedTab?.displayTitle ?? "No terminal selected"
    }

    @MainActor
    func insert(_ text: String, into model: AppModel) throws {
        guard let sessionID,
              let workspace = model.workspaces.first(where: { $0.id.rawValue == workspaceID }),
              workspace.allTabs.contains(where: { $0.terminalSession?.id == sessionID }),
              let process = model.terminalSession(for: sessionID) else {
            throw TerminalSnippetDestinationError.unavailable
        }
        try process.insertLocalText(text)
    }
}

private enum TerminalSnippetDestinationError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "The selected terminal is no longer available. Your draft is still here."
    }
}

/// The upstream presentation owns the destination for the whole sheet lifetime.
struct TerminalSnippetsView: View {
    let model: AppModel
    let destination: TerminalSnippetDestination
    private var workspaceID: UUID { destination.workspaceID }
    private var sessionID: TerminalSessionID? { destination.sessionID }
    private var destinationTitle: String { destination.title }
    private var store: DesktopTerminalSnippetStore { model.terminalSnippetStore }
    @State private var editing = TerminalSnippet(title: "", text: "")
    @State private var message: String?
    @State private var pendingSelection: TerminalSnippet?
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        destination = model.terminalSnippetDestination ?? TerminalSnippetDestination(model: model)
    }

    private var canSave: Bool {
        !editing.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !editing.text.isEmpty
            && editing.text.utf8.count <= DesktopTerminalSnippetStore.maximumUTF8Bytes
            && (editing.workspaceID == nil || model.workspaces.contains { $0.id.rawValue == editing.workspaceID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saved prompts and commands").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Destination: \(destinationTitle)").foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading) {
                    List {
                        ForEach(TerminalSnippet.Kind.allCases, id: \.self) { kind in
                            Section(kind.title) {
                                ForEach(store.snippets.filter {
                                    $0.kind == kind && ($0.workspaceID == nil || $0.workspaceID == workspaceID)
                                }) { snippet in
                                    Button {
                                        if hasUnsavedEdits { pendingSelection = snippet }
                                        else { select(snippet) }
                                    } label: {
                                        VStack(alignment: .leading) {
                                            Text(snippet.title)
                                            if snippet.workspaceID != nil {
                                                Text("This workspace").font(.caption).foregroundStyle(.secondary)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Delete", role: .destructive) {
                                            store.remove(snippet.id)
                                            model.companionHost.workspaceDidChange()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: 220)
                    Button("New entry") {
                        let empty = TerminalSnippet(title: "", text: "")
                        if hasUnsavedEdits { pendingSelection = empty }
                        else { select(empty) }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name", text: $editing.title)
                    Picker("Type", selection: $editing.kind) {
                        ForEach(TerminalSnippet.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Only this workspace", isOn: Binding(
                        get: { editing.workspaceID != nil },
                        set: { editing.workspaceID = $0 ? workspaceID : nil }
                    ))
                    TextEditor(text: $editing.text).font(.body.monospaced())
                        .frame(minWidth: 350, minHeight: 240)
                        .accessibilityLabel("Prompt or command draft")
                    HStack {
                        Button("Save entry") {
                            if store.save(editing) {
                                model.companionHost.workspaceDidChange()
                                message = "Saved on this Mac and shared with connected companions."
                            } else { message = "Could not save: the catalog or entry is too large." }
                        }.disabled(!canSave)
                        Spacer()
                        Button("Insert into terminal") { insert() }
                            .disabled(editing.text.isEmpty || sessionID == nil)
                            .accessibilityIdentifier("insert-saved-terminal-snippet")
                    }
                }
            }
            Text("Stored on this Mac and shared with its paired companions. Review the text and destination before inserting. No Return is added. Multiline insertion requires bracketed paste.")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.callout).accessibilityIdentifier("snippet-outcome") }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 440)
        .alert("Discard unsaved edits?", isPresented: Binding(
            get: { pendingSelection != nil },
            set: { if !$0 { pendingSelection = nil } }
        ), presenting: pendingSelection) { snippet in
            Button("Discard edits", role: .destructive) { select(snippet) }
            Button("Cancel", role: .cancel) { pendingSelection = nil }
        } message: { _ in Text("Save this entry first if you want to keep your changes.") }
    }

    private var hasUnsavedEdits: Bool {
        if let saved = store.snippets.first(where: { $0.id == editing.id }) { return saved != editing }
        return !editing.text.isEmpty || !editing.title.isEmpty
    }

    private func select(_ snippet: TerminalSnippet) {
        editing = snippet
        pendingSelection = nil
        message = nil
    }

    private func insert() {
        do {
            try destination.insert(editing.text, into: model)
            message = "Inserted into \(destinationTitle) without Return. Check the terminal before inserting again."
        } catch { message = error.localizedDescription }
    }
}
