import MyTermRemoteProtocol
import SwiftUI

/// A tab whose agent is talking, shown as the conversation it is having.
///
/// A phone cannot usefully show a hundred-column terminal grid. It can show a conversation, and the
/// agent already keeps one: the Mac reads the agent's own record and sends it as messages, so
/// nothing here parses a screen.
///
/// The raw terminal stays one tap away. Anything this cannot express — a menu, a progress display,
/// a tool with a shape nobody anticipated — is still reachable, and that escape is what makes it
/// safe to show a simplified view by default.
struct AgentConversationScreen: View {
    let tab: RemoteTab
    let store: RemoteSessionStore

    @State private var isShowingTerminal = false
    @State private var draft = ""
    @FocusState private var isWritingReply: Bool
    @State private var isShowingCommands = false
    /// A typed command that would open something on the Mac, held until the person confirms.
    @State private var macOnlyCommand: AgentCommandCatalog.Command?
    /// The last command whose answer went to the Mac's screen, for the bar that says so while
    /// the Mac reads it back, and for as long as it stays when the Mac could not.
    @State private var screenCommand: AgentCommandCatalog.Command?
    @State private var screenCommandTimer: Task<Void, Never>?
    /// This screen's identity to the store, so its stop cannot undo a successor's follow.
    @State private var follower = ConversationFollower()

    var body: some View {
        Group {
            if isShowingTerminal {
                TerminalScreen(tab: tab, store: store)
            } else {
                conversation
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !isShowingTerminal, let conversation = followedConversation {
                    Menu {
                        AgentModelChoices(current: conversation.currentModel) { choice in
                            send(AgentCommandCatalog.command(named: "/model")?.line(with: choice.argument) ?? choice.command)
                        }
                    } label: {
                        // Text rather than a Label: the bar draws a Label as its icon alone, and
                        // the name is the whole point of this item.
                        Text(modelLabel(for: conversation))
                            .font(.subheadline.weight(.medium))
                    }
                    .disabled(!canSendCommands)
                    .accessibilityIdentifier("agent.model")
                }
                Button(isShowingTerminal ? "Conversation" : "Terminal",
                       systemImage: isShowingTerminal ? "bubble.left.and.bubble.right" : "terminal") {
                    isShowingTerminal.toggle()
                }
                .accessibilityIdentifier("agent.toggleTerminal")
            }
        }
        .onAppear { store.followConversation(tabID: tab.id, owner: follower) }
        .onDisappear { store.stopFollowingConversation(tabID: tab.id, owner: follower) }
        .onChange(of: store.screen) { _, screen in
            // The Mac read the dialog: its rows are in the conversation and the bar below offers
            // to dismiss it, so the notice that could only name the Mac has nothing left to say.
            guard screen != nil else { return }
            screenCommandTimer?.cancel()
            screenCommand = nil
        }
        .sheet(isPresented: $isShowingCommands) {
            AgentCommandSheet(run: { command, argument in send(command.line(with: argument)) },
                              currentModel: followedConversation?.currentModel)
                .presentationDetents([.large])
        }
        .alert(
            "This opens on your Mac",
            isPresented: Binding(get: { macOnlyCommand != nil }, set: { if !$0 { macOnlyCommand = nil } }),
            presenting: macOnlyCommand
        ) { command in
            Button("Send anyway") { deliver(command.name); draft = "" }
            Button("Open terminal") { isShowingTerminal = true }
            Button("Cancel", role: .cancel) {}
        } message: { command in
            Text("\(command.name) \(command.description.prefix(1).lowercased())\(command.description.dropFirst()). The phone cannot show it; the terminal can.")
        }
    }

    /// Commands type into the tab, so they are gated as the composer is, and they go nowhere
    /// while the agent is stopped on a permission prompt.
    private var canSendCommands: Bool {
        store.client.allowsMutation && store.promptOptions.isEmpty
    }

    /// One line into the tab, whatever produced it: the reply field, the sheet, a banner.
    ///
    /// The catalog says what to expect afterwards, and that decides what the phone does: warn
    /// before a command that opens on the Mac, or say where the answer went when it cannot be
    /// read back from the transcript.
    /// Returns whether the line went, so a field can keep a draft the person has yet to confirm.
    @discardableResult
    private func send(_ line: String) -> Bool {
        switch AgentCommandCatalog.typed(line) {
        case .macOnly(let command):
            macOnlyCommand = command
            return false
        case .runnable(let command):
            deliver(line)
            if command.outcome == .screen { showScreenNotice(for: command) }
            return true
        case .message, .unknown:
            deliver(line)
            return true
        }
    }

    private func deliver(_ line: String) {
        store.reply(tabID: tab.id, text: line)
    }

    private func showScreenNotice(for command: AgentCommandCatalog.Command) {
        screenCommand = command
        screenCommandTimer?.cancel()
        screenCommandTimer = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            screenCommand = nil
        }
    }

    /// The store's conversation, when it is this tab's. A late one for a tab the person has left is
    /// not shown under this tab's name.
    private var followedConversation: RemoteAgentConversation? {
        guard let conversation = store.conversation, conversation.tabID == tab.id else { return nil }
        return conversation
    }

    /// What the toolbar calls the model. "Model" until an answer has named one.
    private func modelLabel(for conversation: RemoteAgentConversation) -> String {
        conversation.currentModel.flatMap(AgentModelCatalog.label(forModel:)) ?? "Model"
    }

    @ViewBuilder
    private var conversation: some View {
        if let conversation = followedConversation {
            entries(of: conversation)
                .navigationTitle(conversation.title ?? tab.title)
                .navigationBarTitleDisplayMode(.inline)
        } else if store.isLoadingConversation {
            // A session that has just started has not written its record yet, so this is a normal
            // few seconds rather than a failure.
            ProgressView("Reading the conversation…")
                .navigationTitle(tab.title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView(
                "No Conversation",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("This tab is not running an agent MyTerm can read. Open the terminal instead.")
            )
        }
    }

    private func entries(of conversation: RemoteAgentConversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.isTruncated {
                        Text("Earlier messages are not shown.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(conversation.entries) { entry in
                        AgentEntryView(entry: entry)
                            .id(entry.id)
                    }
                    // Scrolling to the last entry lands on its top, which hides a long message's
                    // end. An anchor after it is what puts the newest text on screen.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .accessibilityIdentifier("agent.conversation")
            .onChange(of: conversation.entries.count) {
                withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            // The bars below grow the inset the conversation sits above. Without following them,
            // a prompt's buttons appear over the very question they answer. The scroll waits a
            // turn, because at the moment of the change the inset has not been laid out yet and
            // the bottom the scroll would go to is still the old one.
            .onChange(of: store.promptOptions.isEmpty) {
                DispatchQueue.main.async {
                    withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                }
            }
            .onChange(of: store.screen == nil) {
                DispatchQueue.main.async {
                    withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                }
            }
            .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        }
    }

    /// What the person can send: either an answer to a question the agent is stopped on, or words.
    ///
    /// The two are never offered together. While an agent is waiting on a permission prompt it is
    /// not reading a reply, so a text field there would take something that goes nowhere.
    @ViewBuilder
    private var composer: some View {
        VStack(spacing: 0) {
            if let conversation = followedConversation,
               let notice = AgentCommandCatalog.notice(in: conversation.entries) {
                AgentNoticeBanner(
                    notice: notice,
                    currentModel: conversation.currentModel,
                    isEnabled: canSendCommands,
                    run: { send($0) },
                    openTerminal: { isShowingTerminal = true }
                )
            }
            if let screen = store.screen {
                AgentScreenDismissBar(
                    command: screen.command.name,
                    isEnabled: store.client.allowsMutation && !store.isDismissingScreen,
                    dismiss: { store.dismissScreen(tabID: tab.id) },
                    openTerminal: { isShowingTerminal = true }
                )
            } else if let screenCommand {
                AgentScreenNoticeBar(
                    command: screenCommand,
                    openTerminal: { self.screenCommand = nil; isShowingTerminal = true },
                    dismiss: { self.screenCommand = nil }
                )
            }
            input
        }
    }

    @ViewBuilder
    private var input: some View {
        if !store.client.allowsMutation {
            Label("View only. Typing is turned off on the Mac.", systemImage: "eye")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("agent.viewOnly")
        } else if !store.promptOptions.isEmpty {
            AgentPromptBar(tab: tab, store: store)
        } else {
            AgentReplyBar(
                draft: $draft,
                isWriting: $isWritingReply,
                send: send,
                openCommands: { isShowingCommands = true }
            )
        }
    }

    private static let bottomAnchor = "conversation.bottom"
}

/// An identity for one showing of the conversation screen. A class, because the store keeps it
/// weakly and compares it by reference, as it does the terminal's attachment owner.
private final class ConversationFollower {}

/// Work the agent handed to another agent.
///
/// This is not another tool call and should not read as one. It is the agent bringing somebody in,
/// and the honest thing to say is that the work happened somewhere this screen cannot follow: a
/// teammate's own turns are not in this conversation's record, only the handover and the report.
private struct AgentTeammateView: View {
    let use: RemoteAgentToolUse
    let teammate: RemoteAgentTeammate
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $isExpanded) {
                Text(use.detail)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(heading)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.purple)
                        Text(use.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(3)
                    }
                }
            }

            if use.isPending {
                Label("Still working", systemImage: "ellipsis.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private var icon: String {
        teammate.kind == .delegated ? "person.badge.plus" : "paperplane"
    }

    /// Names the teammate where the call named one. "Explore" says far more than "Agent" does.
    private var heading: String {
        switch teammate.kind {
        case .delegated:
            guard let role = teammate.role else { return "Handed to a teammate" }
            return "Handed to \(role)"
        case .message:
            guard let addressee = teammate.addressee else { return "Message to a teammate" }
            return "Message to \(addressee)"
        }
    }
}

/// The answer to a question the agent has stopped on.
///
/// Every button here names a choice the Mac read off its own screen a moment ago. Tapping one sends
/// the label back, and the Mac only types a digit if that label is still sitting on that number, so
/// a menu that moved under the person answers nothing at all.
private struct AgentPromptBar: View {
    let tab: RemoteTab
    let store: RemoteSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your agent is waiting on this", systemImage: "hand.raised.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.orange)

            ForEach(store.promptOptions) { option in
                Button {
                    store.answerPrompt(tabID: tab.id, option: option)
                } label: {
                    Text(option.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("agent.option.\(option.number)")
            }

            // Always offered, and never one of the numbered choices. Cancelling is the one answer
            // that means the same thing whatever the menu holds.
            Button(role: .destructive) {
                store.denyPrompt(tabID: tab.id)
            } label: {
                Text("Don\u{2019}t allow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("agent.deny")
        }
        .disabled(store.isAnswering)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        // Grouped, so VoiceOver reads the question and its choices as one thing rather than as
        // loose buttons, and so the identifier names a container that can actually be found.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.prompt")
    }
}

/// Saying something to the agent, or running one of its commands.
///
/// A "/" opens the command list, from the button or as the first character typed, because the
/// commands are the one thing a person cannot be expected to remember on a phone.
private struct AgentReplyBar: View {
    @Binding var draft: String
    @FocusState.Binding var isWriting: Bool
    let send: (String) -> Bool
    let openCommands: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: openCommands) {
                Image(systemName: "slash.circle")
                    .font(.title2)
            }
            .accessibilityLabel("Commands")
            .accessibilityIdentifier("agent.openCommands")

            // Grows with what is written, up to a point: a phone reply is often a sentence, and a
            // single line hides most of it.
            TextField("Reply to your agent", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                .focused($isWriting)
                .accessibilityIdentifier("agent.reply")

            Button {
                guard send(draft) else { return }
                draft = ""
                isWriting = false
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("agent.send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: draft) { previous, current in
            // Only as the first character, so a path or a fraction typed later does not interrupt.
            if current == "/", previous.isEmpty { openCommands() }
        }
    }
}

private struct AgentEntryView: View {
    let entry: RemoteAgentEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(entry.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    AgentTextView(text: text, role: entry.role)
                case .thinking(let text):
                    AgentThinkingView(text: text)
                case .toolUse(let use):
                    if let teammate = use.teammate {
                        AgentTeammateView(use: use, teammate: teammate)
                    } else {
                        AgentToolUseView(use: use)
                    }
                case .toolResult(let result):
                    AgentToolResultView(result: result)
                case .image:
                    Label("Image", systemImage: "photo")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .localCommand(let command):
                    AgentLocalCommandView(command: command)
                case .note(let note):
                    AgentNoteView(note: note)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A command the person ran in the agent's own interface, such as `/model`.
///
/// It is not something said to the agent, so it does not get a bubble. It reads like the note a
/// messaging app leaves when a setting changes: centred, small, and out of the way of the talk.
private struct AgentLocalCommandView: View {
    let command: RemoteAgentLocalCommand

    var body: some View {
        VStack(spacing: 3) {
            if let note = AgentCommandCatalog.note(for: command) {
                // The phone's own words for what happened, in place of a line the CLI wrote for
                // its screen.
                Text(note)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                if !command.name.isEmpty {
                    Text(ran)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if !command.output.isEmpty {
                    output
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        // A screen scrolls sideways, and text that scrolls is left out of the combined label.
        .accessibilityValue(command.isScreen ? command.output : "")
        .accessibilityIdentifier("agent.localCommand")
    }

    /// A line is centred under the command. A report, such as `/context`'s, reads as a block. A
    /// screen keeps its columns, which only a fixed-width face and no wrapping can do.
    @ViewBuilder
    private var output: some View {
        if command.isScreen {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(command.output)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        } else if command.output.contains("\n") {
            AgentMarkdownView(text: command.output)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        } else {
            Text(command.output)
                .font(.caption)
                .foregroundStyle(command.isError ? Color.red : .secondary)
                .textSelection(.enabled)
        }
    }

    private var ran: String {
        command.args.isEmpty ? "Ran \(command.name)" : "Ran \(command.name) \(command.args)"
    }
}

/// What was said. A person's message is tinted and indented; the agent's runs full width, because
/// the agent does most of the talking and a bubble for every paragraph wastes a phone's width.
private struct AgentTextView: View {
    let text: String
    let role: RemoteAgentRole

    var body: some View {
        if role == .user {
            AgentMarkdownView(text: text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            AgentMarkdownView(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Agents write markdown. `Text` reads inline markdown from a literal only, so a message that
/// arrives as a value has to be split into blocks here and styled block by block.
private struct AgentMarkdownView: View {
    let text: String

    var body: some View {
        let blocks = AgentMarkdown.blocks(in: text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let body):
                    inline(body)
                case .heading(let level, let body):
                    inline(body)
                        .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                case .bullets(let items):
                    list(items) { _ in Text("•") }
                case .numbered(let items):
                    list(items) { index in Text("\(index + 1).").monospacedDigit() }
                case .tasks(let items):
                    list(items.map(\.text)) { index in
                        Text(Image(systemName: items[index].isDone ? "checkmark.square" : "square"))
                    }
                case .rule:
                    Divider()
                case .table(let header, let alignments, let rows):
                    AgentTableView(header: header, alignments: alignments, rows: rows)
                case .quote(let body):
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1).frame(width: 3)
                            .foregroundStyle(.secondary)
                        inline(body).foregroundStyle(.secondary)
                    }
                case .code(_, let body):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(body)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func list(_ items: [String], marker: @escaping (Int) -> Text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(index).foregroundStyle(.secondary)
                    inline(item)
                }
            }
        }
        .padding(.leading, 4)
    }

    private func inline(_ body: String) -> Text { inlineMarkdown(body) }
}

/// Bold, italics, code spans, and links. A message the parser cannot read is shown as it came.
private func inlineMarkdown(_ body: String) -> Text {
    if let attributed = try? AttributedString(
        markdown: body,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    ) {
        return Text(attributed)
    }
    return Text(body)
}

/// A pipe table as a grid: a bold header, a hairline under each row, and cells in the body font.
///
/// The grid scrolls sideways on its own, as a code block does, so a wide table never makes the
/// conversation scroll sideways. A long cell wraps, so one sentence does not push every other
/// column off the screen. Only the first rows are laid out, because an agent will happily emit a
/// table of every file it touched and a grid's cost grows with its cells.
private struct AgentTableView: View {
    let header: [String]
    let alignments: [AgentMarkdownColumnAlignment]
    let rows: [[String]]

    private static let rowLimit = 60
    private static let cellWidthLimit: CGFloat = 260
    private static let wrappingCharacterCount = 36

    var body: some View {
        let shown = Array(rows.prefix(Self.rowLimit))
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, text in
                        cell(text, column: column, isHeader: true)
                            .gridColumnAlignment(horizontalAlignment(column))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(shown.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, text in
                            cell(text, column: column, isHeader: false)
                        }
                    }
                    if index < shown.count - 1 {
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(.horizontal, 10)
            .accessibilityIdentifier("agent.table")
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        if rows.count > Self.rowLimit {
            Text("… \(rows.count - Self.rowLimit) more rows")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// A cell wraps once it is longer than a phone is wide; a shorter one keeps its natural width.
    ///
    /// The grid sizes every row from its cells' ideal sizes, so a cap on width has to be the ideal
    /// width too, or a long cell wraps inside a row measured for one line. But an ideal width is
    /// what a frame reports when nothing is proposed, so a short cell given the cap would be as
    /// wide as the cap, and every column would be. The length of the text decides which it gets.
    private func cell(_ text: String, column: Int, isHeader: Bool) -> some View {
        let wraps = text.count > Self.wrappingCharacterCount
        return inlineMarkdown(text)
            .fontWeight(isHeader ? .semibold : .regular)
            .multilineTextAlignment(textAlignment(column))
            .frame(
                idealWidth: wraps ? Self.cellWidthLimit : nil,
                maxWidth: wraps ? Self.cellWidthLimit : nil,
                alignment: Alignment(horizontal: horizontalAlignment(column), vertical: .center)
            )
            .padding(.vertical, 6)
    }

    private func alignment(_ column: Int) -> AgentMarkdownColumnAlignment {
        column < alignments.count ? alignments[column] : .leading
    }

    private func horizontalAlignment(_ column: Int) -> HorizontalAlignment {
        switch alignment(column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch alignment(column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Folded away by default. It says what the agent is doing, and it is not what the agent said.
private struct AgentThinkingView: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Thinking", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// What a tool was asked to do.
///
/// The name alone is not enough: "Bash" says nothing about whether the agent is about to list a
/// directory or remove one, and that difference is the whole reason someone checks from a phone.
private struct AgentToolUseView: View {
    let use: RemoteAgentToolUse
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $isExpanded) {
                Text(use.detail)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(use.name)
                            .font(.caption.weight(.semibold))
                        Text(use.summary)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                            // A command that wraps must stay left aligned. Centred, the second line
                            // of a command reads as something nobody would ever type.
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2)
                    }
                }
            }

            if use.isPending {
                // The agent is stopped on this and cannot go on alone. Answering it is the next
                // milestone; saying so is what this screen owes the person today.
                Label("Waiting for your answer on the Mac", systemImage: "hand.raised.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("agent.pending")
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if use.isPending {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange, lineWidth: 1.5)
            }
        }
    }
}

private struct AgentToolResultView: View {
    let result: RemoteAgentToolResult
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                if result.isTruncated {
                    Text("Cut to fit. The whole output is on your Mac.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Label(
                result.isError ? "Failed" : "Result",
                systemImage: result.isError ? "exclamationmark.triangle.fill" : "arrow.turn.down.right"
            )
            .font(.caption)
            .foregroundStyle(result.isError ? Color.red : .secondary)
        }
        .padding(.leading, 10)
    }
}
