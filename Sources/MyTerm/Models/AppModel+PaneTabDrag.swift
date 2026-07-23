import CoreGraphics
import MyTermCore

struct PaneTabDragSource: Equatable {
    let workspaceID: WorkspaceID
    let tabGroupID: TabGroupID
    let tabID: TabID
}

enum PaneTabDropTarget: Equatable {
    case tabStrip(tabGroupID: TabGroupID, insertionIndex: Int)
    case paneCenter(tabGroupID: TabGroupID)
    case paneBody(tabGroupID: TabGroupID, edge: PaneEdge)
}

enum PaneTabDropPreviewFrame {
    static func frame(for edge: PaneEdge, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        return switch edge {
        case .left:
            CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right:
            CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top:
            CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom:
            CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }

    static func centerFrame(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGRect(
            x: size.width * 0.25,
            y: size.height * 0.25,
            width: size.width * 0.5,
            height: size.height * 0.5
        )
    }
}

struct PaneTabDragSession: Equatable {
    let source: PaneTabDragSource
    let startLocation: CGPoint
    var location: CGPoint
    var previewTarget: PaneTabDropTarget?
}

struct PaneTabInsertionFrame: Equatable {
    let tabID: TabID
    let frame: CGRect
}

struct PaneTabDragRegistration: Equatable {
    let workspaceID: WorkspaceID
    let tabGroupID: TabGroupID
    var paneBodyFrame: CGRect?
    var tabStripFrame: CGRect?
    var tabInsertionFrames: [TabID: PaneTabInsertionFrame] = [:]
}

extension AppModel {
    private static let paneTabDragThreshold: CGFloat = 8

    var paneTabDragPreviewTarget: PaneTabDropTarget? {
        paneTabDragSession?.previewTarget
    }

    func registerPaneTabDragPaneBody(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        frame: CGRect
    ) {
        var registration = paneTabDragRegistrations[tabGroupID]
            ?? PaneTabDragRegistration(workspaceID: workspaceID, tabGroupID: tabGroupID)
        registration.paneBodyFrame = frame
        paneTabDragRegistrations[tabGroupID] = registration
        refreshPaneTabDragPreview()
    }

    func registerPaneTabDragTabStrip(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        frame: CGRect
    ) {
        var registration = paneTabDragRegistrations[tabGroupID]
            ?? PaneTabDragRegistration(workspaceID: workspaceID, tabGroupID: tabGroupID)
        registration.tabStripFrame = frame
        paneTabDragRegistrations[tabGroupID] = registration
        refreshPaneTabDragPreview()
    }

    func registerPaneTabDragTab(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        frame: CGRect
    ) {
        var registration = paneTabDragRegistrations[tabGroupID]
            ?? PaneTabDragRegistration(workspaceID: workspaceID, tabGroupID: tabGroupID)
        registration.tabInsertionFrames[tabID] = PaneTabInsertionFrame(tabID: tabID, frame: frame)
        paneTabDragRegistrations[tabGroupID] = registration
    }

    func unregisterPaneTabDragTab(workspaceID: WorkspaceID, tabGroupID: TabGroupID, tabID: TabID) {
        guard var registration = paneTabDragRegistrations[tabGroupID],
              registration.workspaceID == workspaceID else { return }
        registration.tabInsertionFrames[tabID] = nil
        paneTabDragRegistrations[tabGroupID] = registration
        cancelPaneTabDragIfSource(tabGroupID: tabGroupID, tabID: tabID)
    }

    func unregisterPaneTabDragPane(workspaceID: WorkspaceID, tabGroupID: TabGroupID) {
        guard let registration = paneTabDragRegistrations[tabGroupID],
              registration.workspaceID == workspaceID else { return }
        paneTabDragRegistrations[tabGroupID] = nil
        if paneTabDragSession?.source.tabGroupID == tabGroupID {
            cancelPaneTabDrag()
        }
    }

    func updatePaneTabDrag(source: PaneTabDragSource, location: CGPoint) {
        guard source.workspaceID == store.selectedWorkspaceID,
              tab(workspaceID: source.workspaceID, tabGroupID: source.tabGroupID, tabID: source.tabID) != nil else {
            cancelPaneTabDrag()
            return
        }

        if paneTabDragSession?.source == source {
            paneTabDragSession?.location = location
        } else {
            paneTabDragSession = PaneTabDragSession(
                source: source,
                startLocation: location,
                location: location,
                previewTarget: nil
            )
        }
        refreshPaneTabDragPreview()
    }

    @discardableResult
    func finishPaneTabDrag(source: PaneTabDragSource, finalLocation: CGPoint) -> TabMovementResult? {
        guard let session = paneTabDragSession, session.source == source else { return nil }
        defer { cancelPaneTabDrag() }
        guard let target = resolvedPaneTabDragTarget(for: session, at: finalLocation) else { return nil }

        let result: TabMovementResult
        switch target {
        case .tabStrip(let tabGroupID, let insertionIndex):
            result = moveTab(
                workspaceID: source.workspaceID,
                sourceTabGroupID: source.tabGroupID,
                tabID: source.tabID,
                to: tabGroupID,
                at: insertionIndex
            )
        case .paneCenter(let tabGroupID):
            result = moveTab(
                workspaceID: source.workspaceID,
                sourceTabGroupID: source.tabGroupID,
                tabID: source.tabID,
                to: tabGroupID,
                at: nil
            )
        case .paneBody(let tabGroupID, let edge):
            result = moveTabToNewGroup(
                workspaceID: source.workspaceID,
                sourceTabGroupID: source.tabGroupID,
                tabID: source.tabID,
                beside: tabGroupID,
                edge: edge
            )
        }
        if case .failed(let message) = result {
            errorDescription = message
        }
        return result
    }

    func cancelPaneTabDrag() {
        paneTabDragSession = nil
    }

    private func cancelPaneTabDragIfSource(tabGroupID: TabGroupID, tabID: TabID) {
        guard paneTabDragSession?.source.tabGroupID == tabGroupID,
              paneTabDragSession?.source.tabID == tabID else { return }
        cancelPaneTabDrag()
    }

    private func refreshPaneTabDragPreview() {
        guard let session = paneTabDragSession else { return }
        paneTabDragSession?.previewTarget = resolvedPaneTabDragTarget(for: session, at: session.location)
    }

    private func resolvedPaneTabDragTarget(
        for session: PaneTabDragSession,
        at location: CGPoint
    ) -> PaneTabDropTarget? {
        guard session.source.workspaceID == store.selectedWorkspaceID,
              tab(
                workspaceID: session.source.workspaceID,
                tabGroupID: session.source.tabGroupID,
                tabID: session.source.tabID
              ) != nil,
              location.distance(to: session.startLocation) >= Self.paneTabDragThreshold else {
            return nil
        }

        let registrations = paneTabDragRegistrations.values.filter {
            $0.workspaceID == session.source.workspaceID
        }
        if let registration = registrations.first(where: { $0.tabStripFrame?.contains(location) == true }) {
            return .tabStrip(
                tabGroupID: registration.tabGroupID,
                insertionIndex: insertionIndex(
                    in: registration,
                    for: location,
                    source: session.source
                )
            )
        }
        guard let registration = registrations.first(where: { $0.paneBodyFrame?.contains(location) == true }),
              let paneBodyFrame = registration.paneBodyFrame else { return nil }
        let localLocation = CGPoint(
            x: location.x - paneBodyFrame.minX,
            y: location.y - paneBodyFrame.minY
        )
        if PaneTabDropPreviewFrame.centerFrame(in: paneBodyFrame.size).contains(localLocation) {
            return .paneCenter(tabGroupID: registration.tabGroupID)
        }
        return .paneBody(
            tabGroupID: registration.tabGroupID,
            edge: paneEdge(for: localLocation, in: paneBodyFrame.size)
        )
    }

    private func insertionIndex(
        in registration: PaneTabDragRegistration,
        for location: CGPoint,
        source: PaneTabDragSource
    ) -> Int {
        guard let group = store.workspaces
            .first(where: { $0.id == registration.workspaceID })?
            .group(id: registration.tabGroupID) else {
            return 0
        }
        let tabIndexes = Dictionary(uniqueKeysWithValues: group.tabs.enumerated().map { ($0.element.id, $0.offset) })
        let orderedFrames = registration.tabInsertionFrames.values
            .compactMap { frame -> (frame: PaneTabInsertionFrame, tabIndex: Int)? in
                guard let tabIndex = tabIndexes[frame.tabID] else { return nil }
                return (frame, tabIndex)
            }
            .sorted { $0.frame.frame.minX < $1.frame.frame.minX }

        let insertionSlot: Int
        if let target = orderedFrames.first(where: { location.x < $0.frame.frame.midX }) {
            insertionSlot = target.tabIndex
        } else if let last = orderedFrames.last {
            insertionSlot = min(last.tabIndex + 1, group.tabs.count)
        } else {
            insertionSlot = group.tabs.count
        }

        guard registration.tabGroupID == source.tabGroupID,
              let sourceIndex = tabIndexes[source.tabID] else {
            return insertionSlot
        }
        let postRemovalIndex = insertionSlot > sourceIndex ? insertionSlot - 1 : insertionSlot
        return min(max(postRemovalIndex, 0), max(group.tabs.count - 1, 0))
    }

    private func paneEdge(for location: CGPoint, in size: CGSize) -> PaneEdge {
        let distances: [(PaneEdge, CGFloat)] = [
            (.left, location.x / size.width),
            (.top, location.y / size.height),
            (.right, (size.width - location.x) / size.width),
            (.bottom, (size.height - location.y) / size.height),
        ]
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .right
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
