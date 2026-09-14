import MyTermCore
import MyTermRemote
import SwiftUI

struct RemoteTerminalSettingsDraft {
    let original: TerminalPreferences
    var value: TerminalPreferences

    init(_ preferences: TerminalPreferences) {
        original = preferences
        value = preferences
    }

    var patch: TerminalPreferencesOverrides {
        var patch = TerminalPreferencesOverrides()
        if value.fontPostScriptName != original.fontPostScriptName { patch.fontPostScriptName = value.fontPostScriptName }
        if value.fontSize != original.fontSize { patch.fontSize = value.fontSize }
        if value.terminalAppearance != original.terminalAppearance { patch.terminalAppearance = value.terminalAppearance }
        if value.terminalTheme != original.terminalTheme { patch.terminalTheme = value.terminalTheme }
        if value.scrollbackLines != original.scrollbackLines { patch.scrollbackLines = value.scrollbackLines }
        if value.cursorShape != original.cursorShape { patch.cursorShape = value.cursorShape }
        if value.cursorBlink != original.cursorBlink { patch.cursorBlink = value.cursorBlink }
        if value.optionAsMeta != original.optionAsMeta { patch.optionAsMeta = value.optionAsMeta }
        if value.lineEditingMode != original.lineEditingMode { patch.lineEditingMode = value.lineEditingMode }
        if value.shell != original.shell { patch.shell = value.shell }
        if value.newSessionWorkingDirectory != original.newSessionWorkingDirectory {
            patch.newSessionWorkingDirectory = value.newSessionWorkingDirectory
        }
        return patch
    }

    var isValid: Bool {
        guard TerminalPreferences.fontSizeRange.contains(value.fontSize),
              TerminalPreferences.scrollbackLinesRange.contains(value.scrollbackLines),
              !value.fontPostScriptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if case .custom(let path) = value.shell, !path.hasPrefix("/") { return false }
        if case .custom(let directory) = value.newSessionWorkingDirectory,
           !directory.isFileURL || !directory.path.hasPrefix("/") { return false }
        return true
    }

    static let inheritedFields: [RemoteSettingField] = [
        .fontPostScriptName, .fontSize, .terminalAppearance, .terminalTheme,
        .scrollbackLines, .cursorShape, .cursorBlink, .optionAsMeta,
        .lineEditingMode, .shell, .newSessionWorkingDirectory
    ]
}

struct RemoteSettingsEditor: View {
    let scene: SceneModel
    let workspaceID: UUID
    private let connectionID: SavedConnectionID?
    @State private var draft: RemoteTerminalSettingsDraft
    @State private var isSaving = false
    @State private var customDirectoryPath = "/"
    @State private var errorMessage: String?
    @State private var confirmsReset = false
    @Environment(\.dismiss) private var dismiss

    init(scene: SceneModel, workspaceID: UUID, preferences: TerminalPreferences) {
        self.scene = scene
        self.workspaceID = workspaceID
        connectionID = scene.selectedConnectionID
        _draft = State(initialValue: RemoteTerminalSettingsDraft(preferences))
        if case .custom(let directory) = preferences.newSessionWorkingDirectory {
            _customDirectoryPath = State(initialValue: directory.path)
        }
    }

    var body: some View {
        Form {
            Section {
                Text("These settings apply to this workspace on the Mac. Phone text size is adjusted in the terminal toolbar.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            appearance
            keyboard
            newTerminals
            Section {
                Button("Use inherited terminal settings", role: .destructive) { confirmsReset = true }
            } footer: {
                Text("Remove this workspace’s terminal overrides and use its folder or global settings.")
            }
        }
        .disabled(isSaving)
        .navigationTitle("Mac terminal settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save(reset: false) } }
                    .disabled(isSaving || !isValid || draft.patch == TerminalPreferencesOverrides())
            }
        }
        .confirmationDialog("Use inherited terminal settings?", isPresented: $confirmsReset) {
            Button("Use inherited settings", role: .destructive) { Task { await save(reset: true) } }
        }
        .alert("Settings could not be saved", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var appearance: some View {
        Section("Appearance") {
            TextField("Mac font name", text: $draft.value.fontPostScriptName)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Stepper("Font size: \(Int(draft.value.fontSize))", value: $draft.value.fontSize,
                    in: TerminalPreferences.fontSizeRange)
            Picker("Appearance", selection: $draft.value.terminalAppearance) {
                Text("System").tag(TerminalAppearance.system)
                Text("Light").tag(TerminalAppearance.light)
                Text("Dark").tag(TerminalAppearance.dark)
            }
            Picker("Theme", selection: $draft.value.terminalTheme) {
                Text("System").tag(TerminalTheme.system)
                Text("Basic").tag(TerminalTheme.basic)
                Text("Solarized Light").tag(TerminalTheme.solarizedLight)
                Text("Solarized Dark").tag(TerminalTheme.solarizedDark)
            }
            Picker("Cursor", selection: $draft.value.cursorShape) {
                Text("Block").tag(TerminalCursorShape.block)
                Text("Beam").tag(TerminalCursorShape.beam)
                Text("Underline").tag(TerminalCursorShape.underline)
            }
            Toggle("Blink cursor", isOn: $draft.value.cursorBlink)
            LabeledContent("Scrollback lines") {
                TextField("100–100,000", value: $draft.value.scrollbackLines, format: .number)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
        }
    }

    private var keyboard: some View {
        Section("Keyboard") {
            Toggle("Use Option as Meta", isOn: $draft.value.optionAsMeta)
            Picker("Line editing", selection: $draft.value.lineEditingMode) {
                Text("Emacs").tag(TerminalLineEditingMode.emacs)
                Text("Vi").tag(TerminalLineEditingMode.vi)
            }
        }
    }

    private var newTerminals: some View {
        Section {
            Toggle("Use login shell", isOn: Binding(
                get: { draft.value.shell == .loginShell },
                set: { draft.value.shell = $0 ? .loginShell : .custom(path: "/bin/zsh") }
            ))
            if case .custom(let path) = draft.value.shell {
                TextField("Shell path on Mac", text: Binding(
                    get: { path }, set: { draft.value.shell = .custom(path: $0) }
                ))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Picker("Start in", selection: directoryChoice) {
                Text("Home directory").tag(0)
                Text("Active terminal directory").tag(1)
                Text("Custom directory").tag(2)
            }
            if case .custom = draft.value.newSessionWorkingDirectory {
                TextField("Directory on Mac", text: Binding(
                    get: { customDirectoryPath },
                    set: {
                        customDirectoryPath = $0
                        if $0.hasPrefix("/") {
                            draft.value.newSessionWorkingDirectory = .custom(URL(fileURLWithPath: $0))
                        }
                    }
                ))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        } header: { Text("New terminals") } footer: {
            Text("Shell and starting directory changes apply when a new terminal is created.")
        }
    }

    private var directoryChoice: Binding<Int> {
        Binding {
            switch draft.value.newSessionWorkingDirectory {
            case .home: 0
            case .activePane: 1
            case .custom: 2
            }
        } set: { choice in
            switch choice {
            case 1: draft.value.newSessionWorkingDirectory = .activePane
            case 2: draft.value.newSessionWorkingDirectory = .custom(URL(fileURLWithPath: customDirectoryPath.hasPrefix("/") ? customDirectoryPath : "/"))
            default: draft.value.newSessionWorkingDirectory = .home
            }
        }
    }

    private var isValid: Bool {
        guard draft.isValid else { return false }
        if case .custom = draft.value.newSessionWorkingDirectory {
            return customDirectoryPath.hasPrefix("/")
        }
        return true
    }

    private func save(reset: Bool) async {
        guard let connectionID, connectionID == scene.selectedConnectionID,
              scene.connectionPhase == .online else {
            errorMessage = "Reconnect to this Mac before changing its settings."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let payload = RemoteSettingsUpdatePayload(
                scope: .workspace(WorkspaceID(rawValue: workspaceID)),
                patch: reset ? TerminalPreferencesOverrides() : draft.patch,
                reset: reset ? RemoteTerminalSettingsDraft.inheritedFields : []
            )
            _ = try await scene.command(.settingsUpdate, metadata: MessageMetadata(
                hostID: connectionID.hostID, workspaceID: workspaceID
            ), payload: JSONEncoder().encode(payload))
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
