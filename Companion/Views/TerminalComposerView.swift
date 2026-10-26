import MyTermCore
import MyTermRemote
import SwiftUI

struct TerminalComposerView: View {
    let scene: SceneModel
    let route: TerminalRoute
    @Bindable var draft: TerminalComposerDraft
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEditing: Bool
    @State private var snippetPicker: SnippetPickerPresentation?
    @State private var detent: PresentationDetent = .large

    private var surface: TerminalSurfaceState? { scene.terminalStates[route.id] }
    private var canInsert: Bool {
        surface?.ownsControl == true && surface?.isAwaitingCheckpoint == false
            && !draft.isSending && !draft.text.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(route.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Button("Saved prompts and commands", systemImage: "text.badge.star") {
                    isEditing = false
                    snippetPicker = SnippetPickerPresentation()
                }
                .disabled(draft.isSending)
                .accessibilityIdentifier("open-terminal-snippets")
                TextEditor(text: $draft.text)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isEditing)
                    .disabled(draft.isSending)
                    .accessibilityLabel("Terminal draft")
                    .accessibilityIdentifier("terminal-draft")
                    .overlay(alignment: .topLeading) {
                        if draft.text.isEmpty {
                            Text("Write a prompt or command…")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5).padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                if let outcome = draft.insertionOutcome {
                    Text(outcome.message).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("terminal-insertion-outcome")
                }
                if let warning = draft.persistenceErrorMessage {
                    Text(warning).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("terminal-draft-persistence-error")
                }
                if let error = draft.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("terminal-draft-error")
                }
                if surface == nil || surface?.isAwaitingCheckpoint == true {
                    Text("Waiting for this terminal to reconnect. Your draft stays here.").font(.footnote)
                } else if let surface, !surface.ownsControl {
                    HStack {
                        Text("View only. Your draft stays here.").font(.footnote)
                        Spacer()
                        Button(surface.controllerConnectionID == nil ? "Request control" : "Take control") {
                            Task {
                                await scene.requestControl(surface.controllerConnectionID == nil ? .acquire : .takeover,
                                                           route: surface.route)
                            }
                        }
                        .disabled(surface.isAwaitingCheckpoint || surface.isControlRequestPending)
                    }
                }
                if surface?.bracketedPasteMode == false && draft.text.contains(where: { $0.isNewline }) {
                    Text("This terminal does not support bracketed paste. Multiline insertion is blocked; insert one line at a time.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Insert into terminal") { insert(appendReturn: false) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("insert-terminal-draft")
                    Button("Insert + Enter") { insert(appendReturn: true) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("submit-terminal-draft")
                    if draft.isSending { ProgressView().controlSize(.small) }
                }
                .disabled(!canInsert)
                Text("Your draft stays available after inserting. Clear it when you’re finished.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Compose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(draft.isSending)
                        .accessibilityIdentifier("close-terminal-composer")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear", role: .destructive) { draft.text = ""; draft.errorMessage = nil; draft.insertionOutcome = nil }
                        .disabled(draft.isSending || draft.text.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(draft.isSending)
        .sheet(item: $snippetPicker) { _ in
            TerminalSnippetPicker(draft: draft, scene: scene, route: route)
        }
        .task { isEditing = true }
    }

    private func insert(appendReturn: Bool) {
        guard !draft.isSending else { return }
        let text = draft.text
        draft.beginInsertion()
        Task { @MainActor in
            do {
                try await scene.insertComposedText(text, appendReturn: appendReturn, route: route)
                draft.finishInsertion(error: nil)
            } catch {
                draft.finishInsertion(error: error)
            }
        }
    }
}

private struct SnippetPickerPresentation: Identifiable {
    let id = UUID()
}

private struct TerminalSnippetPicker: View {
    @Bindable var draft: TerminalComposerDraft
    let scene: SceneModel
    let route: TerminalRoute
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind = TerminalSnippet.Kind.prompt
    @State private var workspaceOnly = false
    @State private var editing: TerminalSnippet?
    @State private var pendingReplacement: TerminalSnippet?
    @State private var isSaving = false
    @State private var creation = TerminalSnippetCreationState()
    @State private var errorMessage: String?

    private var isOnline: Bool {
        scene.selectedConnectionID == route.connectionID && scene.connectionPhase == .online
            && scene.hasFreshProjection && scene.projection?.terminalSnippets != nil
    }
    private var snippets: [TerminalSnippet] {
        guard scene.selectedConnectionID == route.connectionID else { return [] }
        return scene.projection?.terminalSnippets ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name this prompt or command", text: $title)
                        .accessibilityIdentifier("terminal-snippet-title")
                    Picker("Type", selection: $kind) {
                        ForEach(TerminalSnippet.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Only this workspace", isOn: $workspaceOnly)
                    Button("Save current draft to Mac") {
                        let snippet = TerminalSnippet(id: creation.id, title: title, text: draft.text, kind: kind,
                            workspaceID: workspaceOnly ? route.workspaceID : nil)
                        mutate(snippet)
                    }
                    .disabled(!isOnline || isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || draft.text.isEmpty || draft.text.utf8.count > TerminalComposerDraft.maximumUTF8Bytes)
                    .accessibilityIdentifier("save-terminal-snippet")
                } footer: {
                    Text("Stored on this Mac and shared with its paired companions. Choosing an entry fills Compose for review; it never adds Return.")
                }
                if !isOnline {
                    Section {
                        Text(scene.projection?.terminalSnippets == nil
                             ? "This Mac does not offer a shared catalog yet. Connect to an updated MyTerm host."
                             : "Offline: showing the last catalog received. Reconnect to save, edit or delete entries.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                ForEach(TerminalSnippet.Kind.allCases, id: \.self) { category in
                    Section(category.title) {
                        let entries = snippets.filter {
                            $0.kind == category && ($0.workspaceID == nil || $0.workspaceID == route.workspaceID)
                        }
                        if entries.isEmpty { Text("No saved entries yet.").foregroundStyle(.secondary) }
                        ForEach(entries) { snippet in
                            Button {
                                if draft.text.isEmpty || draft.text == snippet.text { use(snippet) }
                                else { pendingReplacement = snippet }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(snippet.title).foregroundStyle(.primary)
                                    Text(snippet.text).font(.caption.monospaced())
                                        .foregroundStyle(.secondary).lineLimit(3)
                                    if snippet.workspaceID != nil { Text("This workspace").font(.caption2) }
                                }
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) { mutate(nil, deleting: snippet.id) }
                                    .disabled(!isOnline || isSaving)
                                Button("Edit") { editing = snippet }.tint(.blue)
                                    .disabled(!isOnline || isSaving)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Saved prompts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { snippet in
                CompanionSnippetEditor(snippet: snippet, route: route, scene: scene)
            }
            .alert("Replace the current draft?", isPresented: Binding(
                get: { pendingReplacement != nil },
                set: { if !$0 { pendingReplacement = nil } }
            ), presenting: pendingReplacement) { snippet in
                Button("Replace draft", role: .destructive) { use(snippet) }
                Button("Cancel", role: .cancel) { pendingReplacement = nil }
            } message: { _ in Text("Your current text will be replaced. Nothing will be inserted into the terminal.") }
        }
    }

    private func mutate(_ snippet: TerminalSnippet?, deleting id: UUID? = nil) {
        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await scene.updateSharedSnippet(snippet, deleting: id, route: route)
                if let snippet { creation.didConfirmSave(of: snippet.id) }
                title = ""
            } catch { errorMessage = "Change is unconfirmed. Refresh the catalog before trying again. " + error.localizedDescription }
        }
    }

    private func use(_ snippet: TerminalSnippet) {
        draft.text = snippet.text
        draft.errorMessage = nil
        draft.insertionOutcome = nil
        dismiss()
    }
}

private struct CompanionSnippetEditor: View {
    @State var snippet: TerminalSnippet
    let route: TerminalRoute
    let scene: SceneModel
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $snippet.title)
                Picker("Type", selection: $snippet.kind) {
                    ForEach(TerminalSnippet.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Only this workspace", isOn: Binding(
                    get: { snippet.workspaceID != nil },
                    set: { snippet.workspaceID = $0 ? route.workspaceID : nil }
                ))
                TextEditor(text: $snippet.text).font(.body.monospaced()).frame(minHeight: 200)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .disabled(isSaving)
            .navigationTitle("Edit saved entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save to Mac") {
                        isSaving = true
                        Task { @MainActor in
                            defer { isSaving = false }
                            do {
                                try await scene.updateSharedSnippet(snippet, route: route)
                                dismiss()
                            } catch { errorMessage = "Save is unconfirmed. Check the catalog before trying again. " + error.localizedDescription }
                        }
                    }
                    .disabled(isSaving || snippet.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || snippet.text.isEmpty || snippet.text.utf8.count > TerminalComposerDraft.maximumUTF8Bytes)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }
}
