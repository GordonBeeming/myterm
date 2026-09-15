import CoreGraphics
import Foundation
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
    /// Latched the first time the pointer travels past the drag threshold. A press that only
    /// wobbles never lifts the tab, and a lifted tab stays lifted even if the pointer wanders back
    /// near where it started, so the preview cannot flicker between "click" and "drag".
    var isLifted = false
    /// The gesture that started the drag keeps delivering pointer movement until the mouse goes
    /// up, so an Escape press cannot simply drop the session: the next movement would start a new
    /// one. A cancelled session lingers, inert, until release.
    var isCancelled = false
}

struct PaneTabInsertionFrame: Equatable {
    let tabID: TabID
    let frame: CGRect
}

struct PaneTabDragRegistrationID: Hashable {
    private let value = UUID()
}

struct PaneTabDragRegistration: Equatable {
    let workspaceID: WorkspaceID
    let tabGroupID: TabGroupID
    // SwiftUI can overlap outgoing and replacement views for the same logical pane.
    var viewRegistrations: [PaneTabDragRegistrationID: PaneTabDragViewRegistration] = [:]
}

struct PaneTabDragViewRegistration: Equatable {
    var paneBodyFrame: CGRect?
    var tabStripFrame: CGRect?
    var tabInsertionFrames: [TabID: PaneTabInsertionFrame] = [:]
}

private struct PaneTabDragResolvedRegistration {
    let group: PaneTabDragRegistration
    let view: PaneTabDragViewRegistration
}

extension AppModel {
    private static let paneTabDragThreshold: CGFloat = 8

    var paneTabDragPreviewTarget: PaneTabDropTarget? {
        paneTabDragSession?.previewTarget
    }

    func paneTabReorderPreview(in tabGroupID: TabGroupID) -> PaneTabReorderPreview? {
        guard let session = paneTabDragSession,
              session.isLifted,
              !session.isCancelled,
              session.source.tabGroupID == tabGroupID,
              let group = store.workspaces
                .first(where: { $0.id == session.source.workspaceID })?
                .group(id: tabGroupID),
              let sourceIndex = group.tabs.firstIndex(where: { $0.id == session.source.tabID }) else {
            return nil
        }
        var insertionIndex: Int?
        if case .tabStrip(let targetGroupID, let index) = session.previewTarget, targetGroupID == tabGroupID {
            insertionIndex = index
        }
        return PaneTabReorderPreview(
            draggedTabID: session.source.tabID,
            sourceIndex: sourceIndex,
            insertionIndex: insertionIndex,
            pointerOffset: session.location.x - session.startLocation.x
        )
    }

    /// A press that never travelled past the drag threshold is a click on the tab. The strip
    /// selects on release rather than on press so selecting (which scrolls the strip to the
    /// selected tab) can never move the strip underneath a drag that is about to begin.
    func isPaneTabDragClick(source: PaneTabDragSource, releaseLocation: CGPoint) -> Bool {
        guard let session = paneTabDragSession, session.source == source else { return false }
        return !session.isLifted
            && !session.isCancelled
            && releaseLocation.distance(to: session.startLocation) < Self.paneTabDragThreshold
    }

    func registerPaneTabDragPaneBody(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        registrationID: PaneTabDragRegistrationID,
        frame: CGRect
    ) {
        updatePaneTabDragRegistration(
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            registrationID: registrationID
        ) { registration in
            registration.paneBodyFrame = frame
        }
        refreshPaneTabDragPreview()
    }

    func registerPaneTabDragTabStrip(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        registrationID: PaneTabDragRegistrationID,
        frame: CGRect
    ) {
        updatePaneTabDragRegistration(
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            registrationID: registrationID
        ) { registration in
            registration.tabStripFrame = frame
        }
        refreshPaneTabDragPreview()
    }

    func registerPaneTabDragTab(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        registrationID: PaneTabDragRegistrationID,
        tabID: TabID,
        frame: CGRect
    ) {
        updatePaneTabDragRegistration(
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            registrationID: registrationID
        ) { registration in
            registration.tabInsertionFrames[tabID] = PaneTabInsertionFrame(tabID: tabID, frame: frame)
        }
    }

    func unregisterPaneTabDragTab(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        registrationID: PaneTabDragRegistrationID,
        tabID: TabID
    ) {
        guard var registration = paneTabDragRegistrations[tabGroupID],
              registration.workspaceID == workspaceID,
              var viewRegistration = registration.viewRegistrations[registrationID] else { return }
        viewRegistration.tabInsertionFrames[tabID] = nil
        registration.viewRegistrations[registrationID] = viewRegistration
        paneTabDragRegistrations[tabGroupID] = registration
        refreshPaneTabDragPreview()
        guard !registration.viewRegistrations.values.contains(where: { $0.tabInsertionFrames[tabID] != nil }) else {
            return
        }
        cancelPaneTabDragIfSource(tabGroupID: tabGroupID, tabID: tabID)
    }

    func unregisterPaneTabDragPane(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        registrationID: PaneTabDragRegistrationID
    ) {
        guard var registration = paneTabDragRegistrations[tabGroupID],
              registration.workspaceID == workspaceID else { return }
        registration.viewRegistrations[registrationID] = nil
        if registration.viewRegistrations.isEmpty {
            paneTabDragRegistrations[tabGroupID] = nil
        } else {
            paneTabDragRegistrations[tabGroupID] = registration
        }
        refreshPaneTabDragPreview()
        if registration.viewRegistrations.isEmpty,
           paneTabDragSession?.source.tabGroupID == tabGroupID {
            cancelPaneTabDrag()
        }
    }

    func updatePaneTabDrag(source: PaneTabDragSource, location: CGPoint) {
        guard source.workspaceID == store.selectedWorkspaceID,
              tab(workspaceID: source.workspaceID, tabGroupID: source.tabGroupID, tabID: source.tabID) != nil else {
            cancelPaneTabDrag()
            return
        }

        if let session = paneTabDragSession, session.source == source {
            guard !session.isCancelled else { return }
            paneTabDragSession?.location = location
            if location.distance(to: session.startLocation) >= Self.paneTabDragThreshold {
                paneTabDragSession?.isLifted = true
            }
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
            guard tabGroupID != source.tabGroupID else { return nil }
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

    func cancelPaneTabDragUntilRelease() {
        paneTabDragSession?.isCancelled = true
        paneTabDragSession?.previewTarget = nil
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
        guard !session.isCancelled,
              session.source.workspaceID == store.selectedWorkspaceID,
              tab(
                workspaceID: session.source.workspaceID,
                tabGroupID: session.source.tabGroupID,
                tabID: session.source.tabID
              ) != nil,
              session.isLifted || location.distance(to: session.startLocation) >= Self.paneTabDragThreshold else {
            return nil
        }

        let registrations = paneTabDragRegistrations.values
            .flatMap { group in
                group.viewRegistrations.values.map {
                    PaneTabDragResolvedRegistration(group: group, view: $0)
                }
            }
            .filter { $0.group.workspaceID == session.source.workspaceID }
        if let registration = registrations.first(where: { $0.view.tabStripFrame?.contains(location) == true }) {
            return .tabStrip(
                tabGroupID: registration.group.tabGroupID,
                insertionIndex: insertionIndex(
                    in: registration.group,
                    viewRegistration: registration.view,
                    for: location,
                    source: session.source
                )
            )
        }
        guard let registration = registrations.first(where: { $0.view.paneBodyFrame?.contains(location) == true }),
              let paneBodyFrame = registration.view.paneBodyFrame else { return nil }
        let localLocation = CGPoint(
            x: location.x - paneBodyFrame.minX,
            y: location.y - paneBodyFrame.minY
        )
        if PaneTabDropPreviewFrame.centerFrame(in: paneBodyFrame.size).contains(localLocation) {
            return .paneCenter(tabGroupID: registration.group.tabGroupID)
        }
        return .paneBody(
            tabGroupID: registration.group.tabGroupID,
            edge: paneEdge(for: localLocation, in: paneBodyFrame.size)
        )
    }

    private func insertionIndex(
        in registration: PaneTabDragRegistration,
        viewRegistration: PaneTabDragViewRegistration,
        for location: CGPoint,
        source: PaneTabDragSource
    ) -> Int {
        guard let group = store.workspaces
            .first(where: { $0.id == registration.workspaceID })?
            .group(id: registration.tabGroupID) else {
            return 0
        }
        let tabIndexes = Dictionary(uniqueKeysWithValues: group.tabs.enumerated().map { ($0.element.id, $0.offset) })
        let orderedFrames = viewRegistration.tabInsertionFrames.values
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

    private func updatePaneTabDragRegistration(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        registrationID: PaneTabDragRegistrationID,
        update: (inout PaneTabDragViewRegistration) -> Void
    ) {
        var registration = paneTabDragRegistrations[tabGroupID]
            ?? PaneTabDragRegistration(workspaceID: workspaceID, tabGroupID: tabGroupID)
        guard registration.workspaceID == workspaceID else { return }
        var viewRegistration = registration.viewRegistrations[registrationID] ?? PaneTabDragViewRegistration()
        update(&viewRegistration)
        registration.viewRegistrations[registrationID] = viewRegistration
        paneTabDragRegistrations[tabGroupID] = registration
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
