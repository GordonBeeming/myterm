import MyTermRemoteProtocol
import SwiftUI

/// The slash commands a phone can run, offered by name rather than remembered.
///
/// Every row ends in the same place a typed reply does: one line of text into the tab. There is no
/// second way into the agent. What differs is what the phone does afterwards, which the catalog
/// says per command: watch the transcript for the answer, say the answer is on the Mac's screen,
/// or expect the conversation to start over.
struct AgentCommandSheet: View {
    /// Called with the line to type. The sheet dismisses itself once it has called this.
    let run: (AgentCommandCatalog.Command, String?) -> Void
    /// The transcript's last model, so the `/model` row can mark the one in use.
    let currentModel: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(AgentCommandCatalog.Group.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(AgentCommandCatalog.runnable(in: group)) { command in
                            row(for: command)
                        }
                    }
                }
            }
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("agent.commands")
    }

    @ViewBuilder
    private func row(for command: AgentCommandCatalog.Command) -> some View {
        switch command.argument {
        case .none:
            Button {
                choose(command, argument: nil)
            } label: {
                AgentCommandRowLabel(command: command)
            }
            .accessibilityIdentifier("agent.command.\(command.name)")

        case .text(let placeholder, let isRequired):
            AgentCommandTextRow(command: command, placeholder: placeholder, isRequired: isRequired) { argument in
                choose(command, argument: argument)
            }

        case .choice(let options):
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(option) { choose(command, argument: option) }
                        .accessibilityIdentifier("agent.command.\(command.name).\(option)")
                }
            } label: {
                AgentCommandRowLabel(command: command)
            }
            .accessibilityIdentifier("agent.command.\(command.name)")

        case .model:
            Menu {
                AgentModelChoices(current: currentModel) { choice in
                    choose(command, argument: choice.argument)
                }
            } label: {
                AgentCommandRowLabel(command: command)
            }
            .accessibilityIdentifier("agent.command.\(command.name)")
        }
    }

    private func choose(_ command: AgentCommandCatalog.Command, argument: String?) {
        run(command, argument)
        dismiss()
    }
}

/// The name and the CLI's own words for it. Screen-only commands say where the answer goes,
/// because that is the one thing a person cannot tell from the name.
private struct AgentCommandRowLabel: View {
    let command: AgentCommandCatalog.Command

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(command.name)
                    .font(.body.monospaced())
                    .foregroundStyle(.primary)
                if command.outcome == .screen {
                    Image(systemName: "display")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Shown on your Mac")
                }
            }
            Text(command.description)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A command that takes words: the row opens into a field, and the field's Return runs it.
private struct AgentCommandTextRow: View {
    let command: AgentCommandCatalog.Command
    let placeholder: String
    let isRequired: Bool
    let run: (String) -> Void

    @State private var isExpanded = false
    @State private var argument = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            HStack(spacing: 8) {
                TextField(placeholder, text: $argument)
                    .textFieldStyle(.roundedBorder)
                    .focused($isEditing)
                    .onSubmit(submit)
                    .accessibilityIdentifier("agent.command.\(command.name).argument")
                Button("Run", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(isRequired && argument.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("agent.command.\(command.name).run")
            }
            .padding(.vertical, 4)
        } label: {
            AgentCommandRowLabel(command: command)
        }
        .accessibilityIdentifier("agent.command.\(command.name)")
        .onChange(of: isExpanded) { _, expanded in
            if expanded { isEditing = true }
        }
    }

    private func submit() {
        let trimmed = argument.trimmingCharacters(in: .whitespaces)
        guard !isRequired || !trimmed.isEmpty else { return }
        run(trimmed)
    }
}

/// The model choices, as menu items, with the one in use ticked. Shared by the toolbar menu,
/// the notice banner, and the command sheet so all three offer the same list.
struct AgentModelChoices: View {
    let current: String?
    let choose: (AgentModelCatalog.Choice) -> Void

    var body: some View {
        Section("Switch model") {
            ForEach(AgentModelCatalog.choices.filter { !$0.hasExtendedContext }) { choice in
                button(for: choice)
            }
        }
        Section("1M context") {
            ForEach(AgentModelCatalog.choices.filter(\.hasExtendedContext)) { choice in
                button(for: choice)
            }
        }
    }

    private func button(for choice: AgentModelCatalog.Choice) -> some View {
        Button {
            choose(choice)
        } label: {
            if choice == current.flatMap(AgentModelCatalog.choice(matchingModel:)) {
                Label(choice.label, systemImage: "checkmark")
            } else {
                Text(choice.label)
            }
        }
        .accessibilityIdentifier("agent.model.\(choice.argument)")
    }
}

/// The agent has stopped and named the command that would get it going again.
///
/// The way out sits where the person is looking, above the reply field. What the button does
/// follows the catalog: a model notice opens the model list, a command the phone can run runs it,
/// and one that only works on the Mac opens the terminal, where it can be run.
struct AgentNoticeBanner: View {
    let notice: AgentCommandCatalog.Notice
    let currentModel: String?
    let isEnabled: Bool
    let run: (String) -> Void
    let openTerminal: () -> Void

    /// At an accessibility text size the summary and the button do not fit side by side: the
    /// words wrap one to a line beside the button and still get cut. Stacked, both are read whole.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    summary
                    button
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    summary
                    button
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // The tint alone is see-through, and the conversation scrolls underneath this bar.
        .background(Color.orange.opacity(0.12))
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.notice")
    }

    private var summary: some View {
        Label(notice.summary, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Given its height, or the inset it sits in cuts it to a line.
            .fixedSize(horizontal: false, vertical: true)
    }

    private var button: some View {
        action
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("agent.noticeAction")
    }

    @ViewBuilder
    private var action: some View {
        if let command = notice.command, AgentCommandCatalog.command(named: command.name) != nil {
            switch command.argument {
            case .model:
                Menu {
                    AgentModelChoices(current: currentModel) { run(command.line(with: $0.argument)) }
                } label: {
                    Text("Switch model").font(.footnote.weight(.semibold))
                }
                .disabled(!isEnabled)
            case .choice(let options):
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button(option) { run(command.line(with: option)) }
                    }
                } label: {
                    Text(verb(for: command)).font(.footnote.weight(.semibold))
                }
                .disabled(!isEnabled)
            case .none, .text:
                Button {
                    run(command.line())
                } label: {
                    Text(verb(for: command)).font(.footnote.weight(.semibold))
                }
                .disabled(!isEnabled)
            }
        } else {
            Button {
                openTerminal()
            } label: {
                Text("Open terminal").font(.footnote.weight(.semibold))
            }
        }
    }

    /// The button says what will happen, not which command does it.
    private func verb(for command: AgentCommandCatalog.Command) -> String {
        switch command.name {
        case "/compact": "Compact"
        case "/clear": "New session"
        default: "Run \(command.name)"
        }
    }
}

/// A command's dialog is open on the Mac, and the phone has read it into the conversation.
///
/// The dialog stays until something closes it, and while it is up the agent is not reading its
/// prompt. Dismissing sends the Mac the Escape every one of these dialogs offers, and the bar
/// stays while the Mac says the dialog did. The terminal is one tap away for the rest of it: a
/// dialog taller than the Mac's terminal is scrolled there, not here.
struct AgentScreenDismissBar: View {
    let command: String
    let isEnabled: Bool
    let dismiss: () -> Void
    let openTerminal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label("\(command) is open on your Mac", systemImage: "display")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Terminal", action: openTerminal)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("agent.screen.terminal")
            Button("Dismiss", action: dismiss)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!isEnabled)
                .accessibilityIdentifier("agent.screen.dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.screen")
    }
}

/// A command ran and its answer is on the Mac's screen, where the phone could not read it.
struct AgentScreenNoticeBar: View {
    let command: AgentCommandCatalog.Command
    let openTerminal: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label("\(command.name) is shown on your Mac", systemImage: "display")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Terminal", action: openTerminal)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("agent.screenNotice.terminal")
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.screenNotice")
    }
}

/// A note from the agent's machinery: the conversation was compacted, a model was swapped.
/// Centred and small, like a command's row, because it is a fact about the session and not a
/// message from anyone.
struct AgentNoteView: View {
    let note: RemoteAgentNote

    var body: some View {
        Label(note.text, systemImage: note.level == .warning ? "exclamationmark.triangle" : "info.circle")
            .font(.caption)
            .foregroundStyle(note.level == .warning ? Color.orange : .secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(note.text)
            .accessibilityIdentifier("agent.note")
    }
}
