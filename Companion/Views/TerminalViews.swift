import MyTermCore
import MyTermRemote
import PhotosUI
import OSLog
import SwiftTerm
import SwiftUI
import UIKit

struct TerminalUITestFixture: UIViewRepresentable {
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.sendsTerminalResponses = false
        view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        view.acceptsUserInput = false
        view.automaticallyResizesTerminal = false
        view.backgroundColor = .black
        view.feed(text: "\u{001B}[1;36mMyTerm Companion\u{001B}[0m\r\n\r\n$ renderer fixture\r\n✓ SwiftTerm output\r\n$ _")
        view.accessibilityIdentifier = "terminal-fixture"
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}
}

struct TerminalScreen: View {
    @AppStorage("showTerminalKeys") private var showTerminalKeys = false
    let scene: SceneModel
    let route: TerminalRoute
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(spacing: 0) {
            if horizontalSizeClass == .regular, let secondary = scene.secondaryTerminal,
               secondary.id != route.id {
                HStack(spacing: 1) {
                    terminalPane(route)
                    Divider()
                    terminalPane(secondary)
                }
            } else {
                terminalPane(route)
            }
        }
        .background(Color.black)
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(showTerminalKeys ? "Hide terminal keys" : "Show terminal keys", systemImage: "keyboard") {
                    showTerminalKeys.toggle()
                }
                .accessibilityIdentifier("toggle-terminal-keys")
                .accessibilityValue(showTerminalKeys ? "Shown" : "Hidden")
                Menu("Text size", systemImage: "textformat.size") {
                    Button("Larger") { adjustFont(by: 1) }
                    Button("Smaller") { adjustFont(by: -1) }
                    Button("Reset") { setFont(13) }
                }
                if horizontalSizeClass == .regular {
                    Menu("Terminal", systemImage: "terminal") {
                        ForEach(primaryTerminalChoices) { value in
                            Button(value.title) { selectPrimary(value) }
                        }
                    }
                    .disabled(primaryTerminalChoices.isEmpty)
                    Menu("Second terminal", systemImage: "rectangle.split.2x1") {
                        Button("Single terminal") { setSecondary(nil) }
                        ForEach(otherTerminals) { value in
                            Button(value.title) { setSecondary(value) }
                        }
                    }
                }
                Button("Terminal actions", systemImage: "ellipsis.circle") {
                    scene.sheet = .terminalActions(scene.terminalStates[route.id]?.route ?? route)
                }
            }
        }
        .task(id: horizontalSizeClass) {
            if horizontalSizeClass != .regular { await scene.setSecondaryTerminal(nil) }
            await scene.attach(route)
        }
        .onDisappear {
            let secondary = scene.secondaryTerminal
            Task {
                await scene.terminalScreenDidDisappear(route, secondary: secondary)
            }
        }
    }

    private func terminalPane(_ value: TerminalRoute) -> some View {
        CompanionTerminalPane(scene: scene, route: value, showTerminalKeys: showTerminalKeys)
    }

    private var otherTerminals: [TerminalRoute] {
        guard let connectionID = scene.selectedConnectionID else { return [] }
        return scene.projection?.workspaces.flatMap { workspace in
            workspace.groups.flatMap { group in
                group.tabs.compactMap { tab in
                    guard tab.kind == .terminal, let sessionID = tab.terminalSessionID?.rawValue,
                          sessionID != route.sessionID else { return nil }
                    return TerminalRoute(connectionID: connectionID, workspaceID: workspace.id.rawValue,
                                         groupID: group.id.rawValue, tabID: tab.id.rawValue,
                                         sessionID: sessionID, title: tab.title)
                }
            }
        } ?? []
    }

    private var primaryTerminalChoices: [TerminalRoute] {
        otherTerminals.filter { $0.workspaceID == route.workspaceID }
    }

    private func adjustFont(by amount: CGFloat) {
        guard let state = scene.terminalStates[route.id] else { return }
        state.fontSize = min(28, max(8, state.fontSize + amount))
    }

    private func setFont(_ value: CGFloat) {
        scene.terminalStates[route.id]?.fontSize = value
    }

    private func setSecondary(_ value: TerminalRoute?) {
        Task { await scene.setSecondaryTerminal(value) }
    }

    private func selectPrimary(_ value: TerminalRoute) {
        let current = scene.terminalStates[route.id]?.route ?? route
        Task { await scene.selectPrimaryTerminal(value, replacing: current) }
    }
}

struct CompanionTerminalPane: View {
    let scene: SceneModel
    let route: TerminalRoute
    let showTerminalKeys: Bool
    var requestsKeyboardFocus = true
    var onToggleMaximise: (() -> Void)?

    var body: some View {
        if let state = scene.terminalStates[route.id] {
            let currentRoute = state.route
            VStack(spacing: 0) {
                TerminalControlBar(state: state) { action in
                    Task { await scene.requestControl(action, route: currentRoute) }
                } compose: {
                    scene.sheet = .terminalComposer(currentRoute)
                }
                RemoteTerminalView(state: state, showTerminalKeys: showTerminalKeys,
                                   requestsKeyboardFocus: requestsKeyboardFocus && scene.sheet == nil,
                                   onToggleMaximise: onToggleMaximise) { data in
                    Task { await scene.sendInput(data, route: currentRoute) }
                } onPasteImage: { data in
                    Task {
                        do { try await scene.pasteImage(data, route: currentRoute) }
                        catch { scene.errorMessage = error.localizedDescription }
                    }
                } onResize: { columns, rows in
                    Task { await scene.resize(columns: columns, rows: rows, route: currentRoute) }
                } onResync: { error in
                    state.invalidateForCheckpoint()
                    scene.errorMessage = "The terminal view could not be restored: \(error.localizedDescription)"
                    Task { await scene.refreshTerminal(currentRoute) }
                }
                .id(currentRoute.id)
                .overlay(alignment: .bottomTrailing) {
                    if !state.isFollowingOutput {
                        Button("Jump to live", systemImage: "arrow.down.to.line") {
                            state.resumeFollowingOutput()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("terminal-jump-to-live")
                        .padding(12)
                    }
                }
                if showTerminalKeys {
                    TerminalAccessoryBar { bytes in
                        Task { await scene.sendInput(bytes, route: currentRoute) }
                    }
                    .disabled(!state.ownsControl)
                    .accessibilityIdentifier("terminal-keys")
                }
            }
        } else {
            ProgressView("Attaching terminal")
        }
    }
}

private struct TerminalControlBar: View {
    let state: TerminalSurfaceState
    let request: (ControlAction) -> Void
    let compose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.ownsControl ? "keyboard.fill" : "eye")
            Text(status)
                .font(.footnote)
                .lineLimit(1)
            Spacer()
            Button("Compose", systemImage: "square.and.pencil", action: compose)
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("compose-terminal-text")
            if state.isAwaitingCheckpoint {
                ProgressView().controlSize(.small)
            } else if state.isControlRequestPending {
                ProgressView().controlSize(.small)
            } else if state.ownsControl {
                Button("Release") { request(.release) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if state.controllerConnectionID == nil {
                Button("Request control") { request(.acquire) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Button("Take control") { request(.takeover) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    private var status: String {
        if state.isAwaitingCheckpoint { return "Restoring terminal…" }
        if state.isControlRequestPending { return "Requesting control…" }
        if state.ownsControl { return "You have control" }
        if state.controllerConnectionID != nil { return "View only — another device has control" }
        return "View only"
    }
}

struct RemoteTerminalView: UIViewRepresentable {
    private static let logger = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "TerminalRendering")
    let state: TerminalSurfaceState
    let showTerminalKeys: Bool
    var requestsKeyboardFocus = true
    var onToggleMaximise: (() -> Void)?
    let onInput: (Data) -> Void
    let onPasteImage: (Data) -> Void
    let onResize: (Int, Int) -> Void
    let onResync: (Error) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> TerminalView {
        let view = ClipboardTerminalView(frame: .zero)
        view.onPasteImage = { [weak coordinator = context.coordinator] data in
            coordinator?.parent.onPasteImage(data)
        }
        view.onToggleMaximise = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onToggleMaximise?()
        }
        view.terminalDelegate = context.coordinator
        view.sendsTerminalResponses = false
        view.acceptsUserInput = false
        view.automaticallyResizesTerminal = false
        view.usesIndependentViewport = true
        view.coalescesInteractiveOutput = true
        view.onFollowOutputChanged = { [weak coordinator = context.coordinator, weak view] _ in
            guard let view else { return }
            coordinator?.synchronizeViewport(from: view)
        }
        view.onViewportChanged = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.synchronizeViewport(from: view)
        }
        view.linkReporting = .none
        view.accessibilityIdentifier = "remote-terminal"
        context.coordinator.defaultInputAccessoryView = view.inputAccessoryView
        if !showTerminalKeys { view.inputAccessoryView = nil }
        return view
    }

    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.finishViewportCapture(from: view)
        view.onFollowOutputChanged = nil
        view.onViewportChanged = nil
        view.terminalDelegate = nil
        view.updateUiClosed()
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        context.coordinator.parent = self
        if let clipboardView = view as? ClipboardTerminalView {
            clipboardView.canMaximise = onToggleMaximise != nil
        }
        let accessory = showTerminalKeys ? context.coordinator.defaultInputAccessoryView : nil
        if view.inputAccessoryView !== accessory {
            view.inputAccessoryView = accessory
            view.reloadInputViews()
        }
        let gainedControl = !view.acceptsUserInput && state.ownsControl
        let gainedFocus = requestsKeyboardFocus && !context.coordinator.requestedFocus
        context.coordinator.requestedFocus = requestsKeyboardFocus
        if view.font.pointSize != state.fontSize {
            view.font = .monospacedSystemFont(ofSize: state.fontSize, weight: .regular)
        }
        let acceptsControl = state.ownsControl && !state.isAwaitingCheckpoint
        view.automaticallyResizesTerminal = acceptsControl
        if context.coordinator.gridRevision != state.gridRevision {
            context.coordinator.gridRevision = state.gridRevision
            context.coordinator.lastAppliedAuthoritativeSize = (
                state.authoritativeColumns, state.authoritativeRows
            )
            let dimensions = view.getTerminal().getDims()
            if dimensions.cols != state.authoritativeColumns
                || dimensions.rows != state.authoritativeRows {
                view.resize(cols: state.authoritativeColumns, rows: state.authoritativeRows)
            }
        }
        if context.coordinator.checkpointRevision != state.checkpointRevision,
           let checkpoint = state.checkpoint {
            do {
                let viewport = context.coordinator.checkpointRevision < 0
                    ? state.viewport ?? view.captureViewport() : view.captureViewport()
                try view.getTerminal().importCheckpoint(checkpoint)
                view.restoreViewport(viewport)
                context.coordinator.checkpointRevision = state.checkpointRevision
                context.coordinator.outputIndex = 0
                feedPendingOutput(into: view, coordinator: context.coordinator)
                try view.invalidateAfterCheckpointImport()
            } catch {
                view.acceptsUserInput = false
                view.automaticallyResizesTerminal = false
                if context.coordinator.failedCheckpointRevision != state.checkpointRevision {
                    context.coordinator.failedCheckpointRevision = state.checkpointRevision
                    let onResync = onResync
                    Task { @MainActor in onResync(error) }
                }
                return
            }
        } else {
            feedPendingOutput(into: view, coordinator: context.coordinator)
        }
        if context.coordinator.followOutputRevision.map({ $0 != state.followOutputRevision }) ?? state.isFollowingOutput {
            view.followOutput()
        }
        context.coordinator.followOutputRevision = state.followOutputRevision
        context.coordinator.synchronizeViewport(from: view)
        view.acceptsUserInput = acceptsControl
        if gainedControl { view.resizeToFit() }
        if requestsKeyboardFocus && (gainedControl || gainedFocus) {
            let coordinator = context.coordinator
            Task { @MainActor in
                guard state.ownsControl, !state.isAwaitingCheckpoint,
                      coordinator.parent.requestsKeyboardFocus, view.window != nil else { return }
                _ = view.becomeFirstResponder()
            }
        } else if (!acceptsControl || !requestsKeyboardFocus), view.isFirstResponder,
                  !context.coordinator.resignRequested {
            let coordinator = context.coordinator
            coordinator.resignRequested = true
            // UIKit can ask the hosting view for focus while resigning. Defer that
            // work until SwiftUI has finished its representable update.
            Task { @MainActor in
                defer { coordinator.resignRequested = false }
                let current = coordinator.parent
                guard view.window != nil, view.isFirstResponder,
                      !current.state.ownsControl || current.state.isAwaitingCheckpoint
                        || !current.requestsKeyboardFocus else { return }
                _ = view.resignFirstResponder()
            }
        }
    }

    private func feedPendingOutput(into view: TerminalView, coordinator: Coordinator) {
        guard coordinator.outputIndex <= state.outputChunks.count else {
            coordinator.outputIndex = 0
            return
        }
        if coordinator.outputIndex < state.outputChunks.count {
            for bytes in state.outputChunks[coordinator.outputIndex...] {
                let array = Array(bytes)
                view.feed(byteArray: array[...])
            }
            coordinator.outputIndex = state.outputChunks.count
            if state.needsOutputCompaction,
               !coordinator.compactionPending {
                do {
                    let checkpoint = try view.getTerminal().exportCheckpoint()
                    let sequence = state.sequence
                    let revision = state.checkpointRevision
                    coordinator.compactionPending = true
                    Task { @MainActor in
                        defer { coordinator.compactionPending = false }
                        if state.compactRenderedOutput(checkpoint: checkpoint, sequence: sequence, revision: revision) {
                            coordinator.checkpointRevision = state.checkpointRevision
                            coordinator.outputIndex = 0
                        }
                    }
                } catch {
                    Self.logger.warning("Local terminal compaction failed; retaining the display and buffered output.")
                    let revision = state.checkpointRevision
                    coordinator.compactionPending = true
                    Task { @MainActor in
                        defer { coordinator.compactionPending = false }
                        if state.checkpointRevision == revision { state.recordCompactionFailure() }
                    }
                }
            }
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate, @unchecked Sendable {
        var parent: RemoteTerminalView
        var defaultInputAccessoryView: UIView?
        var requestedFocus = false
        var resignRequested = false
        var checkpointRevision = -1
        var compactionPending = false
        var outputIndex = 0
        var gridRevision = -1
        var lastAppliedAuthoritativeSize: (Int, Int)?
        var failedCheckpointRevision = -1
        var followOutputRevision: Int?
        var viewportUpdatePending = false
        var isDismantled = false

        init(parent: RemoteTerminalView) { self.parent = parent }

        @MainActor func finishViewportCapture(from view: TerminalView) {
            isDismantled = true
            // Do not replace cached history with an empty view that never restored it.
            guard checkpointRevision >= 0 else { return }
            let state = parent.state
            if let revision = followOutputRevision, revision != state.followOutputRevision { view.followOutput() }
            let viewport = view.captureViewport()
            state.viewport = viewport
            state.isFollowingOutput = viewport.followsOutput
        }

        @MainActor func synchronizeViewport(from view: TerminalView) {
            guard !isDismantled else { return }
            parent.state.viewport = view.captureViewport()
            guard !viewportUpdatePending else { return }
            viewportUpdatePending = true
            Task { @MainActor [weak self, weak view] in
                guard let self else { return }
                defer { self.viewportUpdatePending = false }
                guard let view, !self.isDismantled else { return }
                let state = self.parent.state
                state.viewport = view.captureViewport()
                if state.isFollowingOutput != view.followsOutput { state.isFollowingOutput = view.followsOutput }
                let bracketed = view.getTerminal().bracketedPasteMode
                if state.bracketedPasteMode != bracketed { state.bracketedPasteMode = bracketed }
            }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            Task { @MainActor [weak self] in
                guard let self, self.parent.state.ownsControl,
                      (self.lastAppliedAuthoritativeSize?.0 != newCols
                        || self.lastAppliedAuthoritativeSize?.1 != newRows) else { return }
                self.parent.onResize(newCols, newRows)
            }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let value = Data(data)
            Task { @MainActor [weak self] in self?.parent.onInput(value) }
        }
        nonisolated func scrolled(source: TerminalView, position: Double) {
            Task { @MainActor [weak self, weak source] in
                guard let source else { return }
                self?.synchronizeViewport(from: source)
            }
        }
        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

private struct TerminalAccessoryBar: View {
    let send: (Data) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                key("esc", [0x1b])
                key("ctrl-c", [0x03])
                key("tab", [0x09])
                key("↑", [0x1b, 0x5b, 0x41])
                key("↓", [0x1b, 0x5b, 0x42])
                key("←", [0x1b, 0x5b, 0x44])
                key("→", [0x1b, 0x5b, 0x43])
                Button("Paste") {
                    if let text = UIPasteboard.general.string { send(Data(text.utf8)) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(8)
        }
        .background(.bar)
    }

    private func key(_ title: String, _ bytes: [UInt8]) -> some View {
        Button(title) { send(Data(bytes)) }.accessibilityLabel("Send \(title)")
    }
}

struct TerminalActionsView: View {
    let scene: SceneModel
    let route: TerminalRoute
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var imageItem: PhotosPickerItem?
    @State private var isSendingImage = false
    @State private var imageProgress = 0.0
    @State private var imageTask: Task<Void, Never>?
    @State private var closeConfirmation: CloseConfirmationPrompt?
    @State private var tabIndex = 0

    init(scene: SceneModel, route: TerminalRoute) {
        self.scene = scene
        self.route = route
        _title = State(initialValue: route.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Control") {
                    if let surface {
                        Text(surface.ownsControl ? "You have control." : "This terminal is view only.")
                            .foregroundStyle(.secondary)
                        if surface.isControlRequestPending {
                            ProgressView("Requesting control")
                        } else if surface.ownsControl {
                            Button("Release control") {
                                Task { await scene.requestControl(.release, route: surface.route) }
                            }
                        } else if surface.controllerConnectionID == nil {
                            Button("Request control") {
                                Task { await scene.requestControl(.acquire, route: surface.route) }
                            }
                        } else {
                            Button("Take control") {
                                Task { await scene.requestControl(.takeover, route: surface.route) }
                            }
                            Text("Taking control makes the other device view only.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Open this terminal before requesting control.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Tab") {
                    TextField("Title", text: $title)
                    Button("Rename") { Task { await rename() } }
                    Stepper("Position \(tabIndex + 1)", value: $tabIndex, in: 0...255)
                    Button("Move to position") { Task { await reorder() } }
                    Menu("Move to group") {
                        ForEach(Array(destinationGroups.enumerated()), id: \.element.id) { index, group in
                            Button("Group \(index + 1)") { Task { await move(to: group) } }
                        }
                    }
                    Menu("Split tab") {
                        ForEach([PaneEdge.left, .right, .top, .bottom], id: \.self) { edge in
                            Button(String(describing: edge).capitalized) { Task { await split(edge) } }
                        }
                    }
                    Button("Close tab", role: .destructive) { Task { await close() } }
                }
                Section("Paste image") {
                    PhotosPicker(selection: $imageItem, matching: .images,
                                 preferredItemEncoding: .current) {
                        Label("Choose image", systemImage: "photo")
                    }
                    .disabled(!canPasteImage || isSendingImage)
                    if isSendingImage {
                        ProgressView(value: imageProgress)
                        Button("Cancel upload", role: .destructive) { imageTask?.cancel() }
                    }
                    if !canPasteImage {
                        Text("Take control before pasting an image.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Terminal actions")
            .toolbar { Button("Done") { dismiss() } }
            .onChange(of: imageItem) { _, item in
                guard let item else { return }
                imageTask?.cancel()
                imageTask = Task { await pasteImage(item) }
            }
            .alert("Close active terminal?", isPresented: Binding(
                get: { closeConfirmation != nil }, set: { if !$0 { closeConfirmation = nil } }
            ), presenting: closeConfirmation) { prompt in
                Button("Close anyway", role: .destructive) {
                    Task { await close(confirmationToken: prompt.token) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                Text("These processes are still running: \(prompt.processNames.joined(separator: ", ")).")
            }
        }
    }

    private var surface: TerminalSurfaceState? { scene.terminalStates[route.id] }
    private var canPasteImage: Bool { surface?.ownsControl == true && surface?.leaseID != nil && surface?.generation != nil }

    private func metadata() -> MessageMetadata {
        MessageMetadata(hostID: route.hostID, sessionID: route.sessionID,
                        workspaceID: route.workspaceID, groupID: route.groupID, tabID: route.tabID)
    }

    private func rename() async {
        do {
            _ = try await scene.command(.tabRename, metadata: metadata(),
                                        payload: try JSONEncoder().encode(RemoteRenamePayload(title: title)))
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private var destinationGroups: [RemoteTabGroupProjection] {
        scene.projection?.workspaces.first(where: { $0.id.rawValue == route.workspaceID })?
            .groups.filter { $0.id.rawValue != route.groupID } ?? []
    }

    private func reorder() async {
        do {
            _ = try await scene.command(.tabReorder, metadata: metadata(),
                                        payload: try JSONEncoder().encode(RemoteTabIndexPayload(index: tabIndex)))
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private func move(to group: RemoteTabGroupProjection) async {
        do {
            _ = try await scene.command(.tabMove, metadata: metadata(),
                                        payload: try JSONEncoder().encode(RemoteTabMovePayload(
                                            destinationGroupID: group.id
                                        )))
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private func split(_ edge: PaneEdge) async {
        do {
            _ = try await scene.command(.tabSplit, metadata: metadata(), payload: try JSONEncoder().encode(
                RemoteTabSplitPayload(targetGroupID: TabGroupID(rawValue: route.groupID), edge: edge)
            ))
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private func close(confirmationToken: String? = nil) async {
        do {
            _ = try await scene.command(.tabClose, metadata: metadata(),
                                        payload: try JSONEncoder().encode(RemoteClosePayload(
                                            confirmedActiveProcesses: confirmationToken != nil,
                                            confirmationToken: confirmationToken
                                        )))
            closeConfirmation = nil
            dismiss()
        } catch let failure as RemoteCommandFailure where failure.code == "confirmation_required" {
            do {
                let value = try JSONDecoder().decode(RemoteCloseConfirmation.self,
                                                     from: failure.result ?? Data())
                closeConfirmation = CloseConfirmationPrompt(processNames: value.processNames,
                                                            token: value.confirmationToken)
            } catch { scene.errorMessage = error.localizedDescription }
        } catch { scene.errorMessage = error.localizedDescription }
    }

    private func pasteImage(_ item: PhotosPickerItem) async {
        isSendingImage = true
        imageProgress = 0
        defer { isSendingImage = false; imageItem = nil; imageTask = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw RemoteError.messageTooLarge
            }
            try await scene.pasteImage(data, route: route) { imageProgress = $0 }
        } catch is CancellationError {
            return
        } catch { scene.errorMessage = error.localizedDescription }
    }
}

@MainActor
final class ClipboardTerminalView: TerminalView {
    var onPasteImage: ((Data) -> Void)?
    var onToggleMaximise: (() -> Void)?
    var canMaximise = false

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        let paste = UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:)))
        paste.wantsPriorityOverSystemBehavior = true
        commands.append(paste)
        if canMaximise {
            let maximise = UIKeyCommand(input: "\r", modifierFlags: [.command, .shift], action: #selector(toggleMaximise(_:)))
            maximise.wantsPriorityOverSystemBehavior = true
            commands.append(maximise)
        }
        return commands
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(toggleMaximise(_:)) { return canMaximise }
        if action == #selector(paste(_:)) { return acceptsUserInput }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func toggleMaximise(_ sender: Any?) { onToggleMaximise?() }

    override func paste(_ sender: Any?) {
        guard acceptsUserInput else { return }
        if let text = UIPasteboard.general.string, !text.isEmpty {
            super.paste(sender)
        } else if UIPasteboard.general.hasImages, let image = UIPasteboard.general.image,
           let data = image.pngData() {
            onPasteImage?(data)
        } else {
            super.paste(sender)
        }
    }
}
