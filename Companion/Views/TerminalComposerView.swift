import MyTermRemote
import SwiftUI

struct TerminalComposerView: View {
    let scene: SceneModel
    let route: TerminalRoute
    @Bindable var draft: TerminalComposerDraft
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEditing: Bool
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
                    Text("This terminal does not support bracketed paste. Inserting multiple lines may run commands.")
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
                    Button("Clear", role: .destructive) { draft.text = ""; draft.errorMessage = nil }
                        .disabled(draft.isSending || draft.text.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(draft.isSending)
        .task { isEditing = true }
    }

    private func insert(appendReturn: Bool) {
        guard !draft.isSending else { return }
        let text = draft.text
        draft.isSending = true
        draft.errorMessage = nil
        Task { @MainActor in
            defer { draft.isSending = false }
            do {
                try await scene.insertComposedText(text, appendReturn: appendReturn, route: route)
                dismiss()
            } catch {
                draft.errorMessage = error.localizedDescription
            }
        }
    }
}
