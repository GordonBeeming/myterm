import MyTermCore
import MyTermRemote
import MyTermUI
import SwiftUI
import UIKit

struct TerminalComposerView: View {
    let scene: SceneModel
    let route: TerminalRoute
    @Bindable var draft: TerminalComposerDraft
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var snippetPicker: SnippetPickerPresentation?
    @State private var detent: PresentationDetent = .large
    @State private var pendingRepeat: ComposerInsertionRequest?

    private var surface: TerminalSurfaceState? { scene.terminalStates[route.id] }
    private var canInsert: Bool {
        canSend && !draft.requiresRepeatConfirmation
    }
    private var canSend: Bool {
        scene.connectionPhase == .online && scene.selectedConnectionID == route.connectionID
            && surface?.ownsControl == true && surface?.isAwaitingCheckpoint == false
            && !draft.isSending && !draft.text.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(route.title).font(.subheadline)
                    .foregroundStyle(Color(uiColor: .label).opacity(0.82))
                    .lineLimit(1)
                Button("Saved prompts and commands", systemImage: "text.badge.star") {
                    isEditing = false
                    snippetPicker = SnippetPickerPresentation()
                }
                .disabled(draft.isSending)
                .tint(Theme.accent)
                .accessibilityIdentifier("open-terminal-snippets")
                TerminalDraftEditor(
                    text: $draft.text,
                    focus: $isEditing,
                    accessibilityLabel: "Terminal draft",
                    accessibilityID: "terminal-draft"
                )
                    .disabled(draft.isSending)
                    .overlay(alignment: .topLeading) {
                        if draft.text.isEmpty {
                            Text("Write a prompt or command…")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 8)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                if let outcome = draft.currentInsertionOutcome {
                    if draft.requiresRepeatConfirmation {
                        Label(outcome == .transportSent ? "Sent over connection" : "Check the terminal before retrying",
                              systemImage: outcome == .transportSent ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.headline)
                    }
                    Text(outcome.message).font(.footnote)
                        .foregroundStyle(Color(uiColor: .label).opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
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
                    Button { insert(appendReturn: false) } label: {
                        Text("Insert").foregroundStyle(Color(uiColor: .label))
                    }
                    .buttonStyle(.bordered)
                    .tint(Color(uiColor: .label))
                    .accessibilityLabel("Insert into terminal")
                    .accessibilityIdentifier("insert-terminal-draft")
                    Button { insert(appendReturn: true) } label: {
                        Text("Insert + Enter").foregroundStyle(Theme.onAccent)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("submit-terminal-draft")
                    if draft.isSending { ProgressView().controlSize(.small) }
                }
                .disabled(!canInsert)
                if draft.requiresRepeatConfirmation {
                    Menu("Insert again…") {
                        Button("Insert into terminal again") { pendingRepeat = ComposerInsertionRequest(action: .insert, text: draft.text) }
                        Button("Insert + Enter again") { pendingRepeat = ComposerInsertionRequest(action: .submit, text: draft.text) }
                    }
                    .disabled(!canSend)
                    .accessibilityIdentifier("repeat-terminal-draft")
                }
                Text("Your draft stays saved after sending.")
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .label).opacity(0.82))
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
        .onChange(of: draft.text) { _, _ in pendingRepeat = nil }
        .alert("Insert this draft again?", isPresented: Binding(
            get: { pendingRepeat != nil },
            set: { if !$0 { pendingRepeat = nil } }
        ), presenting: pendingRepeat) { request in
            Button(request.action == .submit ? "Insert + Enter again" : "Insert again") {
                insert(appendReturn: request.action == .submit, allowRepeat: true, expectedText: request.text)
            }
            Button("Cancel", role: .cancel) { pendingRepeat = nil }
        } message: { _ in
            Text("This text may already be in the terminal. Inserting it again can duplicate your message or command. Check the terminal first.")
        }
    }

    private func insert(appendReturn: Bool, allowRepeat: Bool = false, expectedText: String? = nil) {
        guard canSend, draft.beginInsertion(allowRepeat: allowRepeat, expectedText: expectedText) else { return }
        let text = draft.text
        Task { @MainActor in
            do {
                try await scene.insertComposedText(text, appendReturn: appendReturn, route: route)
                draft.finishInsertion(error: nil)
                dismiss()
            } catch {
                draft.finishInsertion(error: error)
            }
        }
    }
}

private struct TerminalDraftEditor: UIViewRepresentable {
    @Binding var text: String
    var focus: Binding<Bool>? = nil
    var accessibilityLabel: String
    var accessibilityID: String
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 17, weight: .regular)
        )
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textColor = .label
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        // Shell syntax must survive typing, cutting and pasting unchanged.
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityIdentifier = accessibilityID
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.focus = focus
        if view.text != text { view.text = text }
        view.isEditable = isEnabled
        guard let focus, view.isFirstResponder != focus.wrappedValue else { return }
        if focus.wrappedValue {
            DispatchQueue.main.async { [weak view] in
                guard focus.wrappedValue, let view, view.isEditable, view.window != nil else { return }
                view.becomeFirstResponder()
            }
        } else {
            view.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focus: focus) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var focus: Binding<Bool>?

        init(text: Binding<String>, focus: Binding<Bool>?) {
            self.text = text
            self.focus = focus
        }

        func textViewDidChange(_ textView: UITextView) { text.wrappedValue = textView.text }
        func textViewDidBeginEditing(_ textView: UITextView) { focus?.wrappedValue = true }
        func textViewDidEndEditing(_ textView: UITextView) { focus?.wrappedValue = false }
    }
}

private struct ComposerInsertionRequest {
    let action: ComposerInsertionAction
    let text: String
}

private enum ComposerInsertionAction {
    case insert, submit
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
                TerminalDraftEditor(text: $snippet.text, accessibilityLabel: "Saved text",
                                    accessibilityID: "terminal-snippet-text")
                    .frame(minHeight: 200)
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
