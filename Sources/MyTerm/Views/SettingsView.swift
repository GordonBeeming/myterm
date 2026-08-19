import AppKit
import CoreText
import Foundation
import MyTermCore
import MyTermPlatform
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    @State private var passkeyAccess = PasskeyAccessController()
    @State private var defaultTerminal = DefaultTerminalController()
    @State private var agentHooks = AgentHooksController()
    @State private var installedBrowsers = ExternalBrowserCatalog.installedBrowsers()

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider()

            TabView {
                generalSettings
                    .tabItem { Label("General", systemImage: "gearshape") }

                terminalSettings
                    .tabItem { Label("Terminal", systemImage: "terminal") }

                browserSettings
                    .tabItem { Label("Browser", systemImage: "globe") }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(width: 620, height: 590)
        .onChange(of: model.folders.map(\.id)) { _, _ in repairScope() }
        .onChange(of: model.workspaces.map(\.id)) { _, _ in repairScope() }
    }

    private var scope: TerminalSettingsScope {
        model.settingsScope
    }

    private var settingsHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: settingsHeaderIcon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(settingsHeaderTitle)
                    .font(.headline)
                Text(settingsHeaderDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var settingsHeaderIcon: String {
        switch scope {
        case .global: "globe"
        case .folder: "folder"
        case .workspace: "rectangle.stack"
        }
    }

    private var settingsHeaderTitle: String {
        switch scope {
        case .global:
            "Global Settings"
        case .folder(let folderID):
            "Folder Settings — \(model.folders.first(where: { $0.id == folderID })?.title ?? "Unknown Folder")"
        case .workspace(let workspaceID):
            "Workspace Settings — \(model.workspaces.first(where: { $0.id == workspaceID })?.title ?? "Unknown Workspace")"
        }
    }

    private var settingsHeaderDescription: String {
        switch scope {
        case .global:
            "Defaults used across MyTerm unless a folder or workspace overrides them."
        case .folder:
            "Overrides for workspaces in this folder. Settings without an override inherit from Global Settings."
        case .workspace:
            "Overrides for this workspace. Settings without an override inherit from its folder or Global Settings."
        }
    }

    private var updatesFootnote: String {
        var lines = ["Checks GitHub for a newer release once a day. Nothing is downloaded or installed for you."]
        if let command = model.updates.upgradeCommand {
            lines.append("Updating runs `\(command)` in a new tab.")
        } else {
            lines.append("This copy was not installed with Homebrew, so updating opens the release page.")
        }
        if let checked = model.updates.lastCheckedAt {
            lines.append("Last checked \(checked.formatted(date: .abbreviated, time: .shortened)).")
        }
        return lines.joined(separator: " ")
    }

    private var generalSettings: some View {
        Form {
            Section("Workspace appearance") {
                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Compact workspace sidebar",
                    global: \TerminalPreferences.compactSidebar,
                    override: \TerminalPreferencesOverrides.compactSidebar
                ) { value in
                    Toggle("Compact workspace sidebar", isOn: value)
                        .labelsHidden()
                }

                Text("Uses shorter workspace rows so more projects remain visible.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { model.updates.automaticallyChecks },
                    set: { model.updates.automaticallyChecks = $0 }
                ))

                LabeledContent("Installed") {
                    Text(model.updates.currentVersion.isEmpty ? "unknown" : model.updates.currentVersion)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Check Now") { model.checkForUpdates() }
                    if case .checking = model.updates.status {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }

                Text(updatesFootnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Default terminal") {
                Text("Open scripts, executable files, and SSH links in MyTerm. Launch requests reuse the existing MyTerm window.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button(defaultTerminal.isDefault ? "MyTerm Is the Default" : "Make MyTerm the Default") {
                    defaultTerminal.makeDefault()
                }
                .disabled(defaultTerminal.isDefault || defaultTerminal.state == .registering)

                if case .failed(let message) = defaultTerminal.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Default terminal error: \(message)")
                }

                Text("This action applies to the whole app and is not inherited by folders or workspaces.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Agent activity") {
                Text("Mark a tab and its workspace when Claude Code finishes a turn, or asks a question, in a tab you are not looking at. The mark clears when you reach the tab.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button(agentHooks.isInstalled ? "Remove from Claude Code" : "Set Up Claude Code Hooks") {
                        if agentHooks.isInstalled {
                            agentHooks.remove()
                        } else {
                            agentHooks.install()
                        }
                    }

                    if agentHooks.isInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if case .failed(let message) = agentHooks.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Agent hooks error: \(message)")
                }

                Text("This writes three hooks to ~/.claude/settings.json, and removes only those. They report through the pane's terminal and stay silent outside MyTerm, so other terminals are unaffected. Restart a Claude Code session for the change to take effect.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var terminalSettings: some View {
        Form {
            Section("Text") {
                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Font",
                    global: \TerminalPreferences.fontPostScriptName,
                    override: \TerminalPreferencesOverrides.fontPostScriptName
                ) { value in
                    Picker("Font", selection: value) {
                        ForEach(TerminalFontCatalog.fontNames(including: value.wrappedValue), id: \.self) { fontName in
                            Text(TerminalFontCatalog.displayName(for: fontName)).tag(fontName)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 250)
                }

                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Font size",
                    global: \TerminalPreferences.fontSize,
                    override: \TerminalPreferencesOverrides.fontSize
                ) { value in
                    HStack(spacing: 8) {
                        Slider(
                            value: value,
                            in: TerminalPreferences.fontSizeRange,
                            step: 1
                        )
                        .frame(width: 150)

                        TextField("", value: value, format: .number.precision(.fractionLength(0)))
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Font size in points")
                    }
                }

                if let settings = model.resolvedSettings(for: scope) {
                    Text(TerminalFontCatalog.previewText(for: settings.fontPostScriptName))
                        .font(.custom(settings.fontPostScriptName, size: CGFloat(settings.fontSize)))
                        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                        .padding(.horizontal, 10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityLabel("Terminal font preview")

                    if !TerminalFontCatalog.isAvailable(settings.fontPostScriptName) {
                        Label(
                            "\(settings.fontPostScriptName) is unavailable. Terminals will use the system monospaced font until you choose an installed font.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    } else if !TerminalFontCatalog.supportsPowerlineSymbols(settings.fontPostScriptName) {
                        Label(
                            "This font does not include common Powerline and Nerd Font symbols. Choose a patched monospaced font if your prompt shows missing-glyph boxes.",
                            systemImage: "character.book.closed.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                }

                Text("Only installed fixed-pitch fonts are shown. If a saved font is unavailable, MyTerm uses the system monospaced font.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Appearance",
                    global: \TerminalPreferences.terminalAppearance,
                    override: \TerminalPreferencesOverrides.terminalAppearance
                ) { value in
                    Picker("Appearance", selection: value) {
                        ForEach(MyTermCore.TerminalAppearance.allCases, id: \.self) { appearance in
                            Text(appearance.settingsLabel).tag(appearance)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Color theme",
                    global: \TerminalPreferences.terminalTheme,
                    override: \TerminalPreferencesOverrides.terminalTheme
                ) { value in
                    Picker("Color theme", selection: value) {
                        ForEach(TerminalTheme.allCases, id: \.self) { theme in
                            Text(theme.settingsLabel).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }

            Section("New sessions") {
                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Shell",
                    global: \TerminalPreferences.shell,
                    override: \TerminalPreferencesOverrides.shell
                ) { value in
                    ShellSettingControl(value: value)
                }

                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Working directory",
                    global: \TerminalPreferences.newSessionWorkingDirectory,
                    override: \TerminalPreferencesOverrides.newSessionWorkingDirectory
                ) { value in
                    WorkingDirectorySettingControl(value: value)
                }

                if let customShellWarning {
                    Label(customShellWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("Behavior") {
                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Scrollback lines",
                    global: \TerminalPreferences.scrollbackLines,
                    override: \TerminalPreferencesOverrides.scrollbackLines
                ) { value in
                    TextField("Scrollback lines", value: value, format: .number)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                }

                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Cursor shape",
                    global: \TerminalPreferences.cursorShape,
                    override: \TerminalPreferencesOverrides.cursorShape
                ) { value in
                    Picker("Cursor shape", selection: value) {
                        ForEach(MyTermCore.TerminalCursorShape.allCases, id: \.self) { shape in
                            Text(shape.settingsLabel).tag(shape)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Blink cursor",
                    global: \TerminalPreferences.cursorBlink,
                    override: \TerminalPreferencesOverrides.cursorBlink
                ) { value in
                    Toggle("Blink cursor", isOn: value)
                        .labelsHidden()
                }

                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Use Option as Meta",
                    global: \TerminalPreferences.optionAsMeta,
                    override: \TerminalPreferencesOverrides.optionAsMeta
                ) { value in
                    Toggle("Use Option as Meta", isOn: value)
                        .labelsHidden()
                }

                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Shell line editing",
                    global: \TerminalPreferences.lineEditingMode,
                    override: \TerminalPreferencesOverrides.lineEditingMode
                ) { value in
                    Picker("Shell line editing", selection: value) {
                        ForEach(TerminalLineEditingMode.allCases, id: \.self) { mode in
                            Text(mode.settingsLabel).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                Text("Shift-Option word selection uses the configured shell editing mode. Choose Vi to leave those keys to a vi-mode shell.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var browserSettings: some View {
        Form {
            Section("Browser sessions") {
                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Browser data",
                    global: \TerminalPreferences.browserDataScope,
                    override: \TerminalPreferencesOverrides.browserDataScope
                ) { value in
                    Picker("Browser data", selection: value) {
                        ForEach([BrowserDataScope.appWide, .folder, .workspace, .projectDirectory], id: \.self) { dataScope in
                            Text(dataScope.browserDataScopeLabel).tag(dataScope)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                Text("New browser tabs use this profile. Existing tabs keep their current profile.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Web links") {
                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Open web links in",
                    global: \TerminalPreferences.webLinkDestination,
                    override: \TerminalPreferencesOverrides.webLinkDestination
                ) { value in
                    Picker("Open web links in", selection: value) {
                        Text("MyTerm").tag(WebLinkDestination.myterm)
                        Text("Default browser").tag(WebLinkDestination.systemDefaultBrowser)
                        if !installedBrowsers.isEmpty {
                            Divider()
                            ForEach(installedBrowsers) { browser in
                                Text(browser.name)
                                    .tag(WebLinkDestination.application(bundleIdentifier: browser.bundleIdentifier))
                            }
                        }
                        // Keep a browser that is no longer installed visible, so the setting still
                        // reads as the choice that was made rather than as an empty picker.
                        if case .application(let bundleIdentifier) = value.wrappedValue,
                           !installedBrowsers.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
                            Divider()
                            Text("\(bundleIdentifier) (not installed)")
                                .tag(WebLinkDestination.application(bundleIdentifier: bundleIdentifier))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                Text("Links opened from a terminal, and web addresses handed to MyTerm, go to this browser. New Browser Tab always opens MyTerm's own browser.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("File links") {
                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Browser file patterns",
                    global: \TerminalPreferences.browserFilePatterns,
                    override: \TerminalPreferencesOverrides.browserFilePatterns
                ) { value in
                    FilePatternsEditor(
                        patterns: value,
                        accessibilityLabel: "Patterns for files opened in MyTerm",
                        height: 56
                    )
                    .id(scope)
                }

                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Run JavaScript in local pages",
                    global: \TerminalPreferences.allowsLocalFileJavaScript,
                    override: \TerminalPreferencesOverrides.allowsLocalFileJavaScript
                ) { value in
                    Toggle("Run JavaScript in local pages", isOn: value)
                        .labelsHidden()
                }

                Text("Off by default. When enabled, HTML files opened in MyTerm can run their scripts. Changing this reloads open local pages in the affected workspaces.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Open text files with",
                    global: \TerminalPreferences.textFileOpenCommand,
                    override: \TerminalPreferencesOverrides.textFileOpenCommand
                ) { value in
                    TextField("Command", text: value)
                        .labelsHidden()
                        .frame(width: 260)
                        .accessibilityLabel("Command for opening text files")
                }

                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Text file patterns",
                    global: \TerminalPreferences.nativeTextFilePatterns,
                    override: \TerminalPreferencesOverrides.nativeTextFilePatterns
                ) { value in
                    FilePatternsEditor(patterns: value)
                        .id(scope)
                }

                Text("Browser patterns are checked first and open in MyTerm. Text patterns use the command above; unmatched files open in the default macOS application. Enter one pattern per line: use *.json for an extension, or a literal name such as Dockerfile or .gitignore. Put {file} where the quoted path belongs, or MyTerm appends it. Leave the command empty to open matching text files externally.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Passkeys") {
                Text(passkeyDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if passkeyAccess.state == .notDetermined {
                    Button("Allow Passkey Access") {
                        passkeyAccess.requestAccess()
                    }
                }

                Text("Passkey access applies to the signed app and is not inherited by folders or workspaces.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var passkeyDescription: String {
        switch passkeyAccess.state {
        case .unavailable:
            return "Not enabled in this build. MyTerm never stores passkeys; a signed build needs Apple's browser entitlement to pass requests to your credential provider."
        case .notDetermined:
            return "MyTerm never stores passkeys. Allow access so WebKit can pass website requests to your chosen credential provider."
        case .denied:
            return "Passkey access is denied. MyTerm never stores passkeys; macOS and your chosen credential provider handle them."
        case .authorized:
            return "Enabled. MyTerm passes website requests to macOS and never stores passkeys; your chosen credential provider handles them."
        }
    }

    private var customShellWarning: String? {
        guard let settings = model.resolvedSettings(for: scope),
              case .custom(let path) = settings.shell else { return nil }
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard !FileManager.default.isExecutableFile(atPath: expandedPath) else { return nil }
        return "The custom shell is unavailable or not executable. New terminals will use your login shell."
    }

    private func repairScope() {
        switch scope {
        case .global:
            break
        case .folder(let folderID):
            if !model.folders.contains(where: { $0.id == folderID }) {
                model.prepareSettings(for: .global)
            }
        case .workspace(let workspaceID):
            if !model.workspaces.contains(where: { $0.id == workspaceID }) {
                model.prepareSettings(for: .global)
            }
        }
    }
}

private struct FilePatternsEditor: View {
    @Binding private var patterns: [String]
    @State private var draft: String
    @FocusState private var isEditing: Bool
    private let accessibilityLabel: String
    private let height: CGFloat

    init(
        patterns: Binding<[String]>,
        accessibilityLabel: String = "Patterns for files opened as text",
        height: CGFloat = 110
    ) {
        _patterns = patterns
        _draft = State(initialValue: patterns.wrappedValue.joined(separator: "\n"))
        self.accessibilityLabel = accessibilityLabel
        self.height = height
    }

    var body: some View {
        TextEditor(text: $draft)
            .font(.system(.body, design: .monospaced))
            .multilineTextAlignment(.leading)
            .frame(width: 260, height: height)
            .accessibilityLabel(accessibilityLabel)
            .focused($isEditing)
            .onChange(of: draft) { _, newValue in
                let updatedPatterns = newValue.components(separatedBy: .newlines)
                if updatedPatterns != patterns {
                    patterns = updatedPatterns
                }
            }
            .onChange(of: patterns) { _, newValue in
                guard !isEditing else { return }
                draft = newValue.joined(separator: "\n")
            }
            .onChange(of: isEditing) { _, editing in
                if !editing {
                    draft = patterns.joined(separator: "\n")
                }
            }
    }
}

private struct ScopedSettingRow<Value, Control: View>: View {
    @Bindable var model: AppModel
    let scope: TerminalSettingsScope
    let title: String
    let globalKeyPath: WritableKeyPath<TerminalPreferences, Value>
    let overrideKeyPath: WritableKeyPath<TerminalPreferencesOverrides, Value?>
    let control: (Binding<Value>) -> Control

    init(
        model: AppModel,
        scope: TerminalSettingsScope,
        title: String,
        global: WritableKeyPath<TerminalPreferences, Value>,
        override: WritableKeyPath<TerminalPreferencesOverrides, Value?>,
        @ViewBuilder control: @escaping (Binding<Value>) -> Control
    ) {
        self.model = model
        self.scope = scope
        self.title = title
        globalKeyPath = global
        overrideKeyPath = override
        self.control = control
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                HStack(spacing: 12) {
                    control(valueBinding)
                        .disabled(!isEditable)

                    if scope != .global {
                        Toggle("Override", isOn: overrideBinding)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .fixedSize()
                            .accessibilityLabel("Override \(title)")
                    }
                }
            }

            if scope != .global, !hasOverride {
                Text("Inherited from \(inheritanceSource)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(title) is inherited from \(inheritanceSource)")
            }
        }
    }

    private var resolvedValue: Value {
        model.resolvedSettings(for: scope)?[keyPath: globalKeyPath]
            ?? TerminalPreferences.default[keyPath: globalKeyPath]
    }

    private var hasOverride: Bool {
        guard scope != .global else { return true }
        return model.settingsOverrides(for: scope)?[keyPath: overrideKeyPath] != nil
    }

    private var isEditable: Bool {
        scope == .global || hasOverride
    }

    private var valueBinding: Binding<Value> {
        Binding(
            get: { resolvedValue },
            set: { value in
                model.setSetting(
                    value,
                    at: scope,
                    global: globalKeyPath,
                    override: overrideKeyPath
                )
            }
        )
    }

    private var overrideBinding: Binding<Bool> {
        Binding(
            get: { hasOverride },
            set: { shouldOverride in
                if shouldOverride {
                    model.setSetting(
                        resolvedValue,
                        at: scope,
                        global: globalKeyPath,
                        override: overrideKeyPath
                    )
                } else {
                    model.clearSettingOverride(at: scope, overrideKeyPath)
                }
            }
        )
    }

    private var inheritanceSource: String {
        switch scope {
        case .global:
            return "Global"
        case .folder:
            return "Global"
        case .workspace(let workspaceID):
            guard let workspace = model.workspaces.first(where: { $0.id == workspaceID }),
                  let folderID = workspace.folderID,
                  let folder = model.folders.first(where: { $0.id == folderID }) else {
                return "Global"
            }
            return folder.title
        }
    }
}

private struct ShellSettingControl: View {
    @Binding var value: TerminalShell

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Picker("Shell", selection: kindBinding) {
                Text("Login shell").tag(ShellKind.login)
                Text("Custom").tag(ShellKind.custom)
            }
            .labelsHidden()
            .frame(width: 180)

            if case .custom = value {
                TextField("Shell path", text: pathBinding)
                    .frame(width: 260)
                    .accessibilityLabel("Custom shell path")
            }
        }
    }

    private var kindBinding: Binding<ShellKind> {
        Binding(
            get: {
                if case .custom = value { return .custom }
                return .login
            },
            set: { kind in
                switch kind {
                case .login:
                    value = .loginShell
                case .custom:
                    value = .custom(path: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
                }
            }
        )
    }

    private var pathBinding: Binding<String> {
        Binding(
            get: {
                guard case .custom(let path) = value else { return "" }
                return path
            },
            set: { value = .custom(path: $0) }
        )
    }

    private enum ShellKind: Hashable {
        case login
        case custom
    }
}

private struct WorkingDirectorySettingControl: View {
    @Binding var value: NewSessionWorkingDirectoryPolicy

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Picker("Working directory", selection: kindBinding) {
                Text("Home").tag(DirectoryKind.home)
                Text("Active pane").tag(DirectoryKind.activePane)
                Text("Custom").tag(DirectoryKind.custom)
            }
            .labelsHidden()
            .frame(width: 180)

            if case .custom = value {
                HStack(spacing: 6) {
                    TextField("Folder", text: pathBinding)
                        .frame(width: 210)
                        .accessibilityLabel("Custom working directory")

                    Button("Choose…", action: chooseDirectory)
                }
            }
        }
    }

    private var kindBinding: Binding<DirectoryKind> {
        Binding(
            get: {
                switch value {
                case .home: return .home
                case .activePane: return .activePane
                case .custom: return .custom
                }
            },
            set: { kind in
                switch kind {
                case .home:
                    value = .home
                case .activePane:
                    value = .activePane
                case .custom:
                    value = .custom(FileManager.default.homeDirectoryForCurrentUser)
                }
            }
        )
    }

    private var pathBinding: Binding<String> {
        Binding(
            get: {
                guard case .custom(let directory) = value else { return "" }
                return directory.path
            },
            set: { path in
                let expandedPath = (path as NSString).expandingTildeInPath
                value = .custom(URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL)
            }
        )
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if case .custom(let directory) = value {
            panel.directoryURL = directory
        }
        if panel.runModal() == .OK, let directory = panel.url {
            value = .custom(directory.standardizedFileURL)
        }
    }

    private enum DirectoryKind: Hashable {
        case home
        case activePane
        case custom
    }
}

private enum TerminalFontCatalog {
    private static let availableFontNames: [String] = {
        let defaultName = TerminalPreferences.defaultFontPostScriptName
        let available = NSFontManager.shared.availableFonts.filter { name in
            guard let font = NSFont(name: name, size: 13) else { return false }
            return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }
        return [defaultName] + available.filter { $0 != defaultName }.sorted { lhs, rhs in
            displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs)) == .orderedAscending
        }
    }()

    static func fontNames(including selectedName: String) -> [String] {
        guard !availableFontNames.contains(selectedName) else { return availableFontNames }
        return [selectedName] + availableFontNames
    }

    static func isAvailable(_ postScriptName: String) -> Bool {
        NSFont(name: postScriptName, size: 13) != nil
    }

    static func supportsPowerlineSymbols(_ postScriptName: String) -> Bool {
        guard let font = NSFont(name: postScriptName, size: 13) else { return false }
        let coreTextFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        var character = UniChar(0xE0A0)
        var glyph = CGGlyph()
        return CTFontGetGlyphsForCharacters(coreTextFont, &character, &glyph, 1) && glyph != 0
    }

    static func previewText(for postScriptName: String) -> String {
        let base = "Aa 0O 1l  →  ✓"
        return supportsPowerlineSymbols(postScriptName) ? "\(base)  " : base
    }

    static func displayName(for postScriptName: String) -> String {
        if postScriptName == TerminalPreferences.defaultFontPostScriptName {
            return "Default — Menlo"
        }
        return NSFont(name: postScriptName, size: 13)?.displayName ?? "\(postScriptName) — unavailable"
    }
}

private extension MyTermCore.TerminalAppearance {
    var settingsLabel: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

private extension TerminalTheme {
    var settingsLabel: String {
        switch self {
        case .system: return "System"
        case .basic: return "Basic"
        case .solarizedLight: return "Solarized Light"
        case .solarizedDark: return "Solarized Dark"
        }
    }
}

private extension MyTermCore.TerminalCursorShape {
    var settingsLabel: String {
        switch self {
        case .block: return "Block"
        case .beam: return "Beam"
        case .underline: return "Underline"
        }
    }
}

private extension TerminalLineEditingMode {
    var settingsLabel: String {
        switch self {
        case .emacs: return "Emacs"
        case .vi: return "Vi"
        }
    }
}
