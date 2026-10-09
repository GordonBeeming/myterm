import AppKit
import CoreText
import Foundation
import MyTermCore
import MyTermPlatform
import MyTermUI
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    @State private var passkeyAccess = PasskeyAccessController()
    @State private var defaultTerminal = DefaultTerminalController()
    @State private var claudeHooks = AgentHooksController(target: .claude)
    @State private var codexHooks = AgentHooksController(target: .codex)
    @State private var installedBrowsers = ExternalBrowserCatalog.installedBrowsers()

    @State private var section: SettingsSection = .general
    @State private var scopeWorkspaceID: WorkspaceID?
    @State private var scopeFolderID: WorkspaceFolderID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(Theme.Font.ui(13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                ForEach(SettingsSection.allCases) { item in
                    Button { section = item } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(section == item ? Theme.selectedFill : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character(String(item.index + 1))), modifiers: .command)
                    .accessibilityLabel("\(item.rawValue) settings")
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 216)
            .background(Theme.sidebarGround)
            .focusable()
            .onMoveCommand { direction in
                let offset = direction == .up ? -1 : direction == .down ? 1 : 0
                let items = SettingsSection.allCases
                section = items[min(max(section.index + offset, 0), items.count - 1)]
            }
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    settingsHeader
                    switch section {
                    case .general: generalSettings
                    case .terminal: terminalSettings
                    case .browser: browserSettings
                    case .agents: agentSettings
                    case .companion: CompanionSettingsView(companion: model.companionHost)
                    case .permissions: PermissionsSettingsView()
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.windowGround)
        }
        .font(Theme.Font.ui(13, weight: .medium))
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
        .toggleStyle(.switch)
        .pickerStyle(.menu)
        .frame(minWidth: 800, idealWidth: 880, maxWidth: .infinity,
               minHeight: 560, idealHeight: 720, maxHeight: .infinity)
        .onAppear { repairScope() }
        .onChange(of: model.folders.map(\.id)) { _, _ in repairScope() }
        .onChange(of: model.workspaces.map(\.id)) { _, _ in repairScope() }
    }

    private var scope: TerminalSettingsScope {
        model.settingsScope
    }

    private var scopeWorkspace: Workspace {
        if case .workspace(let id) = scope,
           let workspace = model.workspaces.first(where: { $0.id == id }) { return workspace }
        if let id = scopeWorkspaceID,
           let workspace = model.workspaces.first(where: { $0.id == id }) { return workspace }
        return model.selectedWorkspace
    }

    private var scopeFolder: WorkspaceFolder? {
        if case .folder(let id) = scope { return model.folders.first(where: { $0.id == id }) }
        let folderID: WorkspaceFolderID?
        if case .workspace = scope { folderID = scopeWorkspace.folderID }
        else { folderID = scopeFolderID ?? scopeWorkspace.folderID }
        return model.folders.first(where: { $0.id == folderID })
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.rawValue).font(Theme.Font.ui(20, weight: .semibold))
            Text(section.isScoped ? settingsHeaderDescription : "Applies to the whole app.")
                .font(Theme.Font.ui(12))
                .foregroundStyle(Theme.textSecondary)
            if section.isScoped {
                HStack(spacing: 4) {
                    scopeButton(.global) { Text("Global") }
                    if let folder = scopeFolder {
                        scopeButton(.folder(folder.id)) {
                            Image(systemName: "folder.fill").foregroundStyle(folder.color.swiftUIColor)
                            Text(folder.title)
                        }
                    }
                    scopeButton(.workspace(scopeWorkspace.id)) {
                        if let emoji = scopeWorkspace.emoji { Text(emoji) }
                        Text(scopeWorkspace.title)
                    }
                }
                .padding(4)
                .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 8)
                .accessibilityLabel("Settings scope")
            }
        }
    }

    private func scopeButton<Content: View>(_ target: TerminalSettingsScope,
                                            @ViewBuilder content: () -> Content) -> some View {
        Button {
            scopeWorkspaceID = scopeWorkspace.id
            scopeFolderID = scopeFolder?.id
            model.prepareSettings(for: target)
        } label: {
            HStack(spacing: 7, content: content)
                .lineLimit(1)
                .font(Theme.Font.ui(12))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(scope == target ? Theme.selectedFill : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(scope == target ? .isSelected : [])
    }

    private var settingsHeaderDescription: String {
        switch scope {
        case .global:
            "Defaults for every folder and workspace."
        case .folder:
            "Overrides for workspaces in \(scopeFolder?.title ?? "this folder")."
        case .workspace:
            "Overrides for this workspace only."
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
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Workspace sidebar") {
                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Compact workspace sidebar",
                    caption: "Uses shorter workspace rows so more projects remain visible.",
                    global: \TerminalPreferences.compactSidebar,
                    override: \TerminalPreferencesOverrides.compactSidebar
                ) { value in
                    Toggle("Compact workspace sidebar", isOn: value)
                        .labelsHidden()
                }
            }

            SettingsCard("Default terminal · whole app", dimmed: scope != .global) {
                Text("Open scripts, executable files, and SSH links in MyTerm. Launch requests reuse the existing MyTerm window.")
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.textSecondary)

                Button(defaultTerminal.isDefault ? "MyTerm Is the Default" : "Make MyTerm the Default") {
                    defaultTerminal.makeDefault()
                }
                .disabled(defaultTerminal.isDefault || defaultTerminal.state == .registering)

                if case .failed(let message) = defaultTerminal.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.ui(12))
                        .foregroundStyle(.red)
                        .accessibilityLabel("Default terminal error: \(message)")
                }

                Text("This action applies to the whole app and is not inherited by folders or workspaces.")
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.textSecondary)
            }

            SettingsCard("Updates · whole app", dimmed: scope != .global) {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { model.updates.automaticallyChecks },
                    set: { model.updates.automaticallyChecks = $0 }
                ))

                LabeledContent("Installed") {
                    Text(model.updates.currentVersion.isEmpty ? "unknown" : model.updates.currentVersion)
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack {
                    Button("Check Now") { model.checkForUpdates() }
                    if case .checking = model.updates.status {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }

                Text(updatesFootnote)
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.textSecondary)
            }


        }
    }

    private var agentSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Activity hooks · whole app", dimmed: scope != .global) {
                Text("Put a cook beside a tab whose agent is running. He stirs while the agent works, turns blue when it finishes, and turns purple when it has a question. He leaves once you have read the tab, and the tab goes back to its own icon.")
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.textSecondary)

                hookButton(for: claudeHooks)
                hookButton(for: codexHooks)

                Text("Each agent gets its hooks in its own file: five for Claude Code, five for Codex. They report through the pane's terminal and stay silent outside MyTerm, so other terminals are unaffected. Other tools' hooks in the same file are left alone, and removing takes out only what MyTerm wrote. MyTerm refreshes installed hooks at startup. Restart an agent session for the change to take effect.")
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.textSecondary)
            }

            SettingsCard("When an agent needs you · whole app", dimmed: scope != .global) {
                Toggle("Notify when an agent needs you", isOn: Binding(
                    get: { model.agentNotifications.isEnabled },
                    set: { isEnabled in
                        model.agentNotifications.isEnabled = isEnabled
                        // macOS only shows the permission prompt on request, so ask at the moment
                        // the user says yes rather than at launch.
                        if isEnabled {
                            model.agentNotificationPoster.requestAuthorization()
                        }
                    }
                ))

                Picker("Name the notification after", selection: Binding(
                    get: { model.agentNotifications.naming },
                    set: { model.agentNotifications.naming = $0 }
                )) {
                    ForEach(AgentNotificationNaming.allCases, id: \.self) { naming in
                        Text(naming.label).tag(naming)
                    }
                }
                .disabled(!model.agentNotifications.isEnabled)

                Text("A banner arrives only while MyTerm is not the app in front, and carries a swatch of the workspace's folder colour. Clicking it opens the tab. This applies to the whole app and is not inherited by folders or workspaces.")
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.textSecondary)

                Toggle("Show the agent bell in the toolbar", isOn: Binding(
                    get: { model.store.globalSettings.showsAgentNotificationBell },
                    set: { isShown in model.updateGlobalSettings { $0.showsAgentNotificationBell = isShown } }
                ))

                Text("The list of tabs whose agent needs you is kept either way, so turning the bell back on shows what was missed.")
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.textSecondary)
            }

            SettingsCard("Sessions") {
                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Restore agent sessions",
                    caption: "A pane running Claude Code or Codex rejoins its conversation on the next launch, using the agent's own resume command. A pane left at its shell prompt comes back to a shell prompt. Install the hooks above so MyTerm can save the conversation identifier.",
                    global: \TerminalPreferences.restoresAgentSessions,
                    override: \TerminalPreferencesOverrides.restoresAgentSessions
                ) { value in
                    Toggle("Restore agent sessions", isOn: value)
                        .labelsHidden()
                }

                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Name tabs after agent sessions",
                    caption: "A tab takes the name the agent gives its conversation, so /rename in the pane names the tab as well. Until you rename it, the name is the topic Claude Code writes for itself. A tab you named stays as you named it, and that name goes back to Claude Code when the pane rejoins the conversation. Leaving the agent puts the tab back to Terminal. This needs the hooks above.",
                    global: \TerminalPreferences.namesTabsFromAgentSessions,
                    override: \TerminalPreferencesOverrides.namesTabsFromAgentSessions
                ) { value in
                    Toggle("Name tabs after agent sessions", isOn: value)
                        .labelsHidden()
                }
                ScopedSettingRow(
                    model: model, scope: scope,
                    title: "Show the agent's icon when it's idle",
                    global: \TerminalPreferences.showsIdleAgentIcon,
                    override: \TerminalPreferencesOverrides.showsIdleAgentIcon
                ) { value in
                    Toggle("Show the agent's icon when it's idle", isOn: value).labelsHidden()
                }
                HStack(spacing: 8) {
                    AgentIdentityIcon(identity: .claude).frame(width: 16, height: 16)
                    Text("Claude Code")
                    AgentIdentityIcon(identity: .codex).frame(width: 16, height: 16)
                    Text("Codex")
                }
                .font(Theme.Font.ui(12))
                .foregroundStyle(Theme.textSecondary)
                Text("Sits where the cook goes on the workspace and tab, so it shows only while the cook is away. Other programs show nothing.")
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.textSecondary)

            }
        }
    }

    @ViewBuilder
    private func hookButton(for hooks: AgentHooksController) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(hooks.target.displayName)
                Text(hooks.target.fileDescription)
                    .font(Theme.Font.mono(12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            switch hooks.state {
            case .installed:
                Text("Installed")
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.success)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Button("Remove") { hooks.remove() }
                    .accessibilityLabel("Remove hooks from \(hooks.target.displayName)")
            case .notInstalled, .failed:
                Text("Not installed")
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 6))
                Button("Set Up Hooks") { hooks.install() }
                    .accessibilityLabel("Set up \(hooks.target.displayName) hooks")
            }
        }

        if case .failed(let message) = hooks.state {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Font.ui(12))
                .foregroundStyle(.red)
                .accessibilityLabel("\(hooks.target.displayName) hooks error: \(message)")
        }
    }

    private var terminalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Text and colour") {
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
                        .background(Theme.paneGround, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel("Terminal font preview")

                    if !TerminalFontCatalog.isAvailable(settings.fontPostScriptName) {
                        Label(
                            "\(settings.fontPostScriptName) is unavailable. Terminals will use the system monospaced font until you choose an installed font.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(Theme.Font.ui(12))
                        .foregroundStyle(.orange)
                    } else if !TerminalFontCatalog.supportsPowerlineSymbols(settings.fontPostScriptName) {
                        Label(
                            "This font does not include common Powerline and Nerd Font symbols. Choose a patched monospaced font if your prompt shows missing-glyph boxes.",
                            systemImage: "character.book.closed.fill"
                        )
                        .font(Theme.Font.ui(12))
                        .foregroundStyle(.orange)
                    }
                }

                Text("Only installed fixed-pitch fonts are shown. If a saved font is unavailable, MyTerm uses the system monospaced font.")
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.textSecondary)

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

            SettingsCard("New sessions") {
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
                        .font(Theme.Font.ui(12))
                        .foregroundStyle(.orange)
                }
            }

            SettingsCard("Behaviour") {
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
                    caption: "Shift-Option word selection uses the configured shell editing mode. Choose Vi to leave those keys to a vi-mode shell.",
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
            }
        }
    }

    private var browserSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Sign-ins and cookies") {
                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Browser data",
                    caption: "New browser tabs use this profile. Existing tabs keep their current profile.",
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

                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Share sign-ins with companion",
                    caption: "On by default. A paired iPhone or iPad browsing through this Mac reads and writes the same cookies as this profile, so signing in on either device signs you in on both. Turn it off to keep a workspace's sign-ins on this Mac; the companion still keeps its own separate sign-ins for the profile.",
                    global: \TerminalPreferences.sharesBrowserSignInsWithCompanion,
                    override: \TerminalPreferencesOverrides.sharesBrowserSignInsWithCompanion
                ) { value in
                    Toggle("Share sign-ins with companion", isOn: value)
                        .labelsHidden()
                }
            }

            SettingsCard("Links from terminals") {
                ScopedSettingRow(
                    model: model,
                    scope: scope,
                    title: "Open web links in",
                    caption: "Links opened from a terminal, and web addresses handed to MyTerm, go to this browser. New Browser Tab always opens MyTerm's own browser.",
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
            }

            SettingsCard("File links") {
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
                    caption: "Off by default. When enabled, HTML files opened in MyTerm can run their scripts. Changing this reloads open local pages in the affected workspaces.",
                    global: \TerminalPreferences.allowsLocalFileJavaScript,
                    override: \TerminalPreferencesOverrides.allowsLocalFileJavaScript
                ) { value in
                    Toggle("Run JavaScript in local pages", isOn: value)
                        .labelsHidden()
                }

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
                    caption: "Browser patterns are checked first and open in MyTerm. Text patterns use the command above; unmatched files open in the default macOS application. Enter one pattern per line: use *.json for an extension, or a literal name such as Dockerfile or .gitignore. Put {file} where the quoted path belongs, or MyTerm appends it. Leave the command empty to open matching text files externally.",
                    global: \TerminalPreferences.nativeTextFilePatterns,
                    override: \TerminalPreferencesOverrides.nativeTextFilePatterns
                ) { value in
                    FilePatternsEditor(patterns: value)
                        .id(scope)
                }
            }

            SettingsCard("Passkeys · whole app", dimmed: scope != .global) {
                Text(passkeyDescription)
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.textSecondary)

                if passkeyAccess.state == .notDetermined {
                    Button("Allow Passkey Access") {
                        passkeyAccess.requestAccess()
                    }
                }

                Text("Passkey access applies to the signed app and is not inherited by folders or workspaces.")
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
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
    let caption: String?
    let globalKeyPath: WritableKeyPath<TerminalPreferences, Value>
    let overrideKeyPath: WritableKeyPath<TerminalPreferencesOverrides, Value?>
    let control: (Binding<Value>) -> Control

    init(
        model: AppModel,
        scope: TerminalSettingsScope,
        title: String,
        caption: String? = nil,
        global: WritableKeyPath<TerminalPreferences, Value>,
        override: WritableKeyPath<TerminalPreferencesOverrides, Value?>,
        @ViewBuilder control: @escaping (Binding<Value>) -> Control
    ) {
        self.model = model
        self.scope = scope
        self.title = title
        self.caption = caption
        globalKeyPath = global
        overrideKeyPath = override
        self.control = control
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Font.ui(13, weight: .medium))
                if let caption {
                    Text(caption)
                        .font(Theme.Font.ui(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if scope != .global {
                    HStack(spacing: 0) {
                        Text("\(hasOverride ? "Overrides" : "Inherited from") \(inheritanceSource) · ")
                        Button(hasOverride ? "Reset" : "Override") {
                            overrideBinding.wrappedValue = !hasOverride
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("\(hasOverride ? "Reset" : "Override") \(title)")
                    }
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(hasOverride ? Theme.accent : Theme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            control(valueBinding)
                .disabled(!isEditable)
                .opacity(isEditable ? 1 : 0.45)
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
                  let folder = model.folders.first(where: { $0.id == folderID }),
                  folder.settingsOverrides?[keyPath: overrideKeyPath] != nil else {
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

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", terminal = "Terminal", browser = "Browser"
    case agents = "Agents", companion = "Companion", permissions = "Permissions"

    var id: Self { self }
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    var isScoped: Bool { self != .companion && self != .permissions }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .terminal: "terminal"
        case .browser: "globe"
        case .agents: "sparkles"
        case .companion: "iphone.and.arrow.forward"
        case .permissions: "lock.shield"
        }
    }
}

// Flatten conditional content so each visible row gets the same inset and separator.
@MainActor
@resultBuilder
struct SettingsRowsBuilder {
    static func buildExpression<V: View>(_ view: V) -> [AnyView] { [AnyView(view)] }
    static func buildBlock(_ parts: [AnyView]...) -> [AnyView] { parts.flatMap { $0 } }
    static func buildOptional(_ part: [AnyView]?) -> [AnyView] { part ?? [] }
    static func buildEither(first: [AnyView]) -> [AnyView] { first }
    static func buildEither(second: [AnyView]) -> [AnyView] { second }
    static func buildArray(_ parts: [[AnyView]]) -> [AnyView] { parts.flatMap { $0 } }
}

struct SettingsCard: View {
    let title: String
    let dimmed: Bool
    let rows: [AnyView]
    let insetRows: Bool

    init(_ title: String, dimmed: Bool = false, insetRows: Bool = true, @SettingsRowsBuilder content: () -> [AnyView]) {
        self.title = title
        self.dimmed = dimmed
        self.insetRows = insetRows
        rows = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.Font.ui(12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    rows[index]
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, insetRows ? 14 : 0)
                        .padding(.horizontal, insetRows ? 16 : 0)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
        }
        .opacity(dimmed ? 0.5 : 1)
    }
}
