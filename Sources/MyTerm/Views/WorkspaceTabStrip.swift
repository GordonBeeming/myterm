import AppKit
import MyTermCore
import SwiftUI

enum MiddleClickTabInteraction {
    static func shouldClose(
        buttonNumber: Int,
        eventWindowNumber: Int,
        viewWindowNumber: Int?,
        locationInView: NSPoint,
        viewBounds: NSRect
    ) -> Bool {
        buttonNumber == 2
            && viewWindowNumber == eventWindowNumber
            && viewBounds.contains(locationInView)
    }
}

@MainActor
final class MiddleClickMonitorLifecycle {
    private var monitor: Any?

    var isMonitoring: Bool { monitor != nil }

    func start(install: () -> Any?) {
        guard monitor == nil else { return }
        monitor = install()
    }

    func stop(remove: (Any) -> Void) {
        guard let monitor else { return }
        self.monitor = nil
        remove(monitor)
    }
}

struct WorkspaceTabStrip: View {
    let model: AppModel
    let workspaceID: WorkspaceID
    let tabGroup: TabGroup

    var body: some View {
        ScrollViewReader { scrollProxy in
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 4) {
                        ForEach(Array(tabGroup.tabs.enumerated()), id: \.element.id) { entry in
                            tabItem(entry.element)
                                .id(entry.element.id)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .onAppear { scrollToSelectedTab(using: scrollProxy) }
                .onChange(of: tabGroup.selectedTabID) { _, _ in
                    scrollToSelectedTab(using: scrollProxy)
                }

                Divider().frame(height: 20)

                Menu {
                    Button("New Terminal Tab") { model.createTerminalTab(in: tabGroup.id) }
                    Button("New Browser Tab") { model.createBrowserTab(in: tabGroup.id) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .focusable(false)
                .accessibilityLabel("Add tab to pane")
                .help("Add Tab")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                PaneTabStripFrameReporter(
                    model: model,
                    workspaceID: workspaceID,
                    tabGroupID: tabGroup.id
                )
            )
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                model.cancelPaneTabDrag()
            }
        }
    }

    private func scrollToSelectedTab(using scrollProxy: ScrollViewProxy) {
        scrollProxy.scrollTo(tabGroup.selectedTabID, anchor: .center)
    }

    private func tabItem(_ tab: MyTermCore.Tab) -> some View {
        let source = PaneTabDragSource(
            workspaceID: workspaceID,
            tabGroupID: tabGroup.id,
            tabID: tab.id
        )
        return WorkspaceTabItem(
            tab: tab,
            source: source,
            isSelected: tab.id == tabGroup.selectedTabID,
            title: title(for: tab),
            select: { model.selectTab(tab.id, in: tabGroup.id) },
            rename: { model.beginRenamingTab(tab.id, in: tabGroup.id) },
            close: { model.closeTab(tab.id) },
            dragChanged: { location in model.updatePaneTabDrag(source: source, location: location) },
            dragEnded: { location in model.finishPaneTabDrag(source: source, finalLocation: location) },
            dragCancelled: { model.cancelPaneTabDrag() },
            moveToPreviousPane: { move(tab, relativeTo: tabGroup.id, offset: -1) },
            moveToNextPane: { move(tab, relativeTo: tabGroup.id, offset: 1) },
            moveToNewPane: { edge in move(tab, toNewPaneBeside: tabGroup.id, edge: edge) }
        )
        .background(
            PaneTabInsertionFrameReporter(
                model: model,
                workspaceID: workspaceID,
                tabGroupID: tabGroup.id,
                tabID: tab.id
            )
        )
    }

    private func title(for tab: MyTermCore.Tab) -> String {
        tab.customTitle ?? tab.automaticDisplayTitle
    }

    @discardableResult
    private func move(_ tab: MyTermCore.Tab, relativeTo groupID: TabGroupID, offset: Int) -> TabMovementResult? {
        let groups = model.selectedWorkspace.layout.orderedGroups
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return nil }
        let destinationIndex = index + offset
        guard groups.indices.contains(destinationIndex) else { return nil }
        return model.moveTab(
            workspaceID: workspaceID,
            sourceTabGroupID: groupID,
            tabID: tab.id,
            to: groups[destinationIndex].id,
            at: nil
        )
    }

    @discardableResult
    private func move(_ tab: MyTermCore.Tab, toNewPaneBeside groupID: TabGroupID, edge: PaneEdge) -> TabMovementResult {
        model.moveTabToNewGroup(
            workspaceID: workspaceID,
            sourceTabGroupID: groupID,
            tabID: tab.id,
            beside: groupID,
            edge: edge
        )
    }
}

private struct PaneTabStripFrameReporter: View {
    let model: AppModel
    let workspaceID: WorkspaceID
    let tabGroupID: TabGroupID

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear
                .onAppear {
                    model.registerPaneTabDragTabStrip(
                        workspaceID: workspaceID,
                        tabGroupID: tabGroupID,
                        frame: frame
                    )
                }
                .onChange(of: frame) { _, updatedFrame in
                    model.registerPaneTabDragTabStrip(
                        workspaceID: workspaceID,
                        tabGroupID: tabGroupID,
                        frame: updatedFrame
                    )
                }
        }
    }
}

private struct PaneTabInsertionFrameReporter: View {
    let model: AppModel
    let workspaceID: WorkspaceID
    let tabGroupID: TabGroupID
    let tabID: TabID

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear
                .onAppear {
                    model.registerPaneTabDragTab(
                        workspaceID: workspaceID,
                        tabGroupID: tabGroupID,
                        tabID: tabID,
                        frame: frame
                    )
                }
                .onChange(of: frame) { _, updatedFrame in
                    model.registerPaneTabDragTab(
                        workspaceID: workspaceID,
                        tabGroupID: tabGroupID,
                        tabID: tabID,
                        frame: updatedFrame
                    )
                }
                .onDisappear {
                    model.unregisterPaneTabDragTab(
                        workspaceID: workspaceID,
                        tabGroupID: tabGroupID,
                        tabID: tabID
                    )
                }
        }
    }
}

private struct WorkspaceTabItem: View {
    let tab: MyTermCore.Tab
    let source: PaneTabDragSource
    let isSelected: Bool
    let title: String
    let select: () -> Void
    let rename: () -> Void
    let close: () -> Void
    let dragChanged: (CGPoint) -> Void
    let dragEnded: (CGPoint) -> Void
    let dragCancelled: () -> Void
    let moveToPreviousPane: () -> Void
    let moveToNextPane: () -> Void
    let moveToNewPane: (PaneEdge) -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fontWeight(isSelected ? .medium : .regular)
                    Spacer(minLength: 18)
                }
                .padding(.horizontal, 8)
                .frame(width: 136, height: 26, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundStyle)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(borderStyle, lineWidth: isSelected ? 1 : 0.5)
                }
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel(title)
            .accessibilityValue(isSelected ? "Selected tab" : "Tab")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help(title)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .focusable(false)
            .opacity(isSelected || isHovering ? 1 : 0)
            .allowsHitTesting(isSelected || isHovering)
            .accessibilityHidden(!(isSelected || isHovering))
            .accessibilityLabel("Close \(title) tab")
            .help("Close Tab")
            .padding(.trailing, 2)
        }
        .frame(width: 136, height: 26)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in dragChanged(value.location) }
                .onEnded { value in dragEnded(value.location) }
        )
        .overlay {
            MiddleClickTabHandler(close: close).allowsHitTesting(false)
        }
        .onHover { isHovering = $0 }
        .onDisappear(perform: dragCancelled)
        .contextMenu {
            Button("Rename Tab…", action: rename)
            Divider()
            Button("Move to Previous Pane", action: moveToPreviousPane)
            Button("Move to Next Pane", action: moveToNextPane)
            Menu("Move to New Pane") {
                Button("Left", action: { moveToNewPane(.left) })
                Button("Right", action: { moveToNewPane(.right) })
                Button("Above", action: { moveToNewPane(.top) })
                Button("Below", action: { moveToNewPane(.bottom) })
            }
            Divider()
            Button("Close Tab", action: close)
        }
        .accessibilityAction(named: "Move to previous pane", moveToPreviousPane)
        .accessibilityAction(named: "Move to next pane", moveToNextPane)
        .accessibilityAction(named: "Move to new left pane") { moveToNewPane(.left) }
        .accessibilityAction(named: "Move to new right pane") { moveToNewPane(.right) }
        .accessibilityAction(named: "Move to new pane above") { moveToNewPane(.top) }
        .accessibilityAction(named: "Move to new pane below") { moveToNewPane(.bottom) }
    }

    private var backgroundStyle: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    private var borderStyle: Color {
        isSelected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2)
    }

    private var iconName: String { tab.isBrowser ? "globe" : "terminal" }
}

private struct MiddleClickTabHandler: NSViewRepresentable {
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(close: close) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.startMonitoring(view: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.close = close
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        var close: () -> Void
        private weak var view: NSView?
        private let monitorLifecycle = MiddleClickMonitorLifecycle()

        init(close: @escaping () -> Void) { self.close = close }

        func startMonitoring(view: NSView) {
            self.view = view
            monitorLifecycle.start {
                NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                    let shouldClose = MainActor.assumeIsolated {
                        guard let self, let view = self.view else { return false }
                        let location = view.convert(event.locationInWindow, from: nil)
                        guard MiddleClickTabInteraction.shouldClose(
                            buttonNumber: event.buttonNumber,
                            eventWindowNumber: event.windowNumber,
                            viewWindowNumber: view.window?.windowNumber,
                            locationInView: location,
                            viewBounds: view.bounds
                        ) else { return false }
                        self.close()
                        return true
                    }
                    return shouldClose ? nil : event
                }
            }
        }

        func stopMonitoring() {
            monitorLifecycle.stop { NSEvent.removeMonitor($0) }
            view = nil
        }
    }
}
