import Foundation

public struct TerminalSession: Codable, Equatable, Hashable, Sendable, Identifiable {
    public static let maximumRecentTextLines = 50
    public static let maximumRecentTextBytes = 8 * 1024
    public let id: TerminalSessionID
    public let paneID: PaneID
    public var workingDirectory: URL?
    public var recentText: String?

    public init(
        id: TerminalSessionID = TerminalSessionID(),
        paneID: PaneID = PaneID(),
        workingDirectory: URL? = nil,
        recentText: String? = nil
    ) {
        self.id = id
        self.paneID = paneID
        self.workingDirectory = workingDirectory
        self.recentText = Self.boundedRecentText(recentText)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case paneID
        case workingDirectory
        case recentText
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TerminalSessionID.self, forKey: .id)
        paneID = try container.decodeIfPresent(PaneID.self, forKey: .paneID) ?? PaneID()
        workingDirectory = try container.decodeIfPresent(URL.self, forKey: .workingDirectory)
        recentText = Self.boundedRecentText(try? container.decodeIfPresent(String.self, forKey: .recentText))
    }

    public static func boundedRecentText(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        var bounded = value.split(separator: "\n", omittingEmptySubsequences: false).suffix(maximumRecentTextLines).joined(separator: "\n")
        while bounded.lengthOfBytes(using: .utf8) > maximumRecentTextBytes, !bounded.isEmpty { bounded.removeFirst() }
        return bounded.isEmpty ? nil : bounded
    }
}

public enum BrowserDataScope: String, Codable, Equatable, Hashable, Sendable {
    case appWide = "app-wide"
    case workspace
    case projectDirectory = "project-directory"
}

public struct BrowserDataProfile: Codable, Equatable, Hashable, Sendable {
    public let scope: BrowserDataScope
    public let persistentStoreID: UUID
    public let projectDirectory: URL?

    public init(
        scope: BrowserDataScope,
        persistentStoreID: UUID,
        projectDirectory: URL? = nil
    ) {
        self.scope = scope
        self.persistentStoreID = persistentStoreID
        self.projectDirectory = projectDirectory?.standardizedFileURL
    }

    private enum CodingKeys: String, CodingKey {
        case scope
        case persistentStoreID
        case projectDirectory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try container.decode(BrowserDataScope.self, forKey: .scope)
        persistentStoreID = try container.decode(UUID.self, forKey: .persistentStoreID)
        projectDirectory = try container.decodeIfPresent(URL.self, forKey: .projectDirectory)?.standardizedFileURL
    }
}

public struct BrowserSession: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: BrowserSessionID
    public let paneID: PaneID
    public var url: URL
    public var profile: BrowserDataProfile?

    public init(
        id: BrowserSessionID = BrowserSessionID(),
        paneID: PaneID = PaneID(),
        url: URL,
        profile: BrowserDataProfile? = nil
    ) {
        self.id = id
        self.paneID = paneID
        self.url = url
        self.profile = profile
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case paneID
        case url
        case profile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(BrowserSessionID.self, forKey: .id)
        paneID = try container.decodeIfPresent(PaneID.self, forKey: .paneID) ?? PaneID()
        url = try container.decode(URL.self, forKey: .url)
        profile = try container.decodeIfPresent(BrowserDataProfile.self, forKey: .profile)
    }
}

public enum SplitOrientation: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

public enum PaneFocusDirection: Equatable, Sendable {
    case left
    case up
    case right
    case down
}

public enum SplitNode: Codable, Equatable, Hashable, Sendable {
    case terminal(TerminalSession)
    case browser(BrowserSession)
    case horizontal([SplitNode])
    case vertical([SplitNode])

    private enum CodingKeys: String, CodingKey {
        case type
        case session
        case children
    }

    private enum NodeType: String, Codable {
        case terminal
        case browser
        case horizontal
        case vertical
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)

        switch type {
        case .terminal:
            self = .terminal(try container.decode(TerminalSession.self, forKey: .session))
        case .browser:
            self = .browser(try container.decode(BrowserSession.self, forKey: .session))
        case .horizontal:
            self = .horizontal(try container.decodeIfPresent(LossyArray<SplitNode>.self, forKey: .children)?.elements ?? [])
        case .vertical:
            self = .vertical(try container.decodeIfPresent(LossyArray<SplitNode>.self, forKey: .children)?.elements ?? [])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .terminal(let session):
            try container.encode(NodeType.terminal, forKey: .type)
            try container.encode(session, forKey: .session)
        case .browser(let session):
            try container.encode(NodeType.browser, forKey: .type)
            try container.encode(session, forKey: .session)
        case .horizontal(let children):
            try container.encode(NodeType.horizontal, forKey: .type)
            try container.encode(children, forKey: .children)
        case .vertical(let children):
            try container.encode(NodeType.vertical, forKey: .type)
            try container.encode(children, forKey: .children)
        }
    }

    public var terminalSessions: [TerminalSession] {
        switch self {
        case .terminal(let session):
            return [session]
        case .browser:
            return []
        case .horizontal(let children), .vertical(let children):
            return children.flatMap(\.terminalSessions)
        }
    }

    public var terminalSessionIDs: [TerminalSessionID] {
        terminalSessions.map(\.id)
    }

    public var browserSessions: [BrowserSession] {
        switch self {
        case .browser(let session):
            return [session]
        case .terminal:
            return []
        case .horizontal(let children), .vertical(let children):
            return children.flatMap(\.browserSessions)
        }
    }

    public var browserSessionIDs: [BrowserSessionID] {
        browserSessions.map(\.id)
    }

    public var paneIDs: [PaneID] {
        switch self {
        case .terminal(let session):
            return [session.paneID]
        case .browser(let session):
            return [session.paneID]
        case .horizontal(let children), .vertical(let children):
            return children.flatMap(\.paneIDs)
        }
    }

    public var stableID: SplitNodeID {
        switch self {
        case .terminal(let session): return SplitNodeID(rawValue: session.paneID.rawValue)
        case .browser(let session): return SplitNodeID(rawValue: session.paneID.rawValue)
        case .horizontal(let children), .vertical(let children):
            return children.first?.stableID ?? SplitNodeID()
        }
    }

    public var splitLayouts: [SplitPaneLayout] { paneLayouts().compactMap(SplitPaneLayout.init) }

    public func contains(_ sessionID: TerminalSessionID) -> Bool {
        terminalSessionIDs.contains(sessionID)
    }

    public func contains(paneID: PaneID) -> Bool {
        paneIDs.contains(paneID)
    }

    public func session(for paneID: PaneID) -> TerminalSession? {
        terminalSessions.first { $0.paneID == paneID }
    }

    public func browser(for paneID: PaneID) -> BrowserSession? {
        browserSessions.first { $0.paneID == paneID }
    }

    public func browser(id: BrowserSessionID) -> BrowserSession? {
        browserSessions.first { $0.id == id }
    }

    public func adjacentPaneID(to paneID: PaneID, direction: PaneFocusDirection) -> PaneID? {
        let panes = paneLayouts()
        guard let source = panes.first(where: { $0.paneID == paneID }) else { return nil }

        return panes
            .filter { $0.paneID != paneID }
            .compactMap { candidate -> (layout: PaneLayout, primary: Double, secondary: Double)? in
                let primary: Double
                let overlap: Double
                let secondary: Double

                switch direction {
                case .left:
                    primary = source.minX - candidate.maxX
                    overlap = min(source.maxY, candidate.maxY) - max(source.minY, candidate.minY)
                    secondary = abs(source.centerY - candidate.centerY)
                case .up:
                    primary = source.minY - candidate.maxY
                    overlap = min(source.maxX, candidate.maxX) - max(source.minX, candidate.minX)
                    secondary = abs(source.centerX - candidate.centerX)
                case .right:
                    primary = candidate.minX - source.maxX
                    overlap = min(source.maxY, candidate.maxY) - max(source.minY, candidate.minY)
                    secondary = abs(source.centerY - candidate.centerY)
                case .down:
                    primary = candidate.minY - source.maxY
                    overlap = min(source.maxX, candidate.maxX) - max(source.minX, candidate.minX)
                    secondary = abs(source.centerX - candidate.centerX)
                }

                guard primary >= -PaneLayout.epsilon, overlap > PaneLayout.epsilon else { return nil }
                return (candidate, max(primary, 0), secondary)
            }
            .min {
                if abs($0.primary - $1.primary) > PaneLayout.epsilon {
                    return $0.primary < $1.primary
                }
                return $0.secondary < $1.secondary
            }?
            .layout.paneID
    }

    public func adjacentTerminalSessionID(
        to sessionID: TerminalSessionID,
        direction: PaneFocusDirection
    ) -> TerminalSessionID? {
        guard let source = terminalSessions.first(where: { $0.id == sessionID }),
              let targetPaneID = adjacentPaneID(to: source.paneID, direction: direction) else { return nil }
        return session(for: targetPaneID)?.id
    }

    @discardableResult
    public mutating func insert(
        _ node: SplitNode,
        beside paneID: PaneID,
        orientation: SplitOrientation
    ) -> Bool {
        switch self {
        case .terminal(let existing):
            guard existing.paneID == paneID else { return false }
            self = orientation.node(children: [.terminal(existing), node])
            return true
        case .browser(let existing):
            guard existing.paneID == paneID else { return false }
            self = orientation.node(children: [.browser(existing), node])
            return true
        case .horizontal(var children):
            for index in children.indices where children[index].insert(node, beside: paneID, orientation: orientation) {
                self = .horizontal(children)
                return true
            }
            return false
        case .vertical(var children):
            for index in children.indices where children[index].insert(node, beside: paneID, orientation: orientation) {
                self = .vertical(children)
                return true
            }
            return false
        }
    }

    @discardableResult
    public mutating func insert(
        _ session: TerminalSession,
        beside existingSessionID: TerminalSessionID,
        orientation: SplitOrientation
    ) -> Bool {
        switch self {
        case .terminal(let existing):
            guard existing.id == existingSessionID else { return false }
            self = orientation.node(children: [.terminal(existing), .terminal(session)])
            return true
        case .browser:
            return false
        case .horizontal(var children):
            for index in children.indices {
                if children[index].insert(session, beside: existingSessionID, orientation: orientation) {
                    self = .horizontal(children)
                    return true
                }
            }
            return false
        case .vertical(var children):
            for index in children.indices {
                if children[index].insert(session, beside: existingSessionID, orientation: orientation) {
                    self = .vertical(children)
                    return true
                }
            }
            return false
        }
    }

    @discardableResult
    public mutating func updateWorkingDirectory(
        _ workingDirectory: URL?,
        for sessionID: TerminalSessionID
    ) -> Bool {
        switch self {
        case .terminal(var session):
            guard session.id == sessionID else { return false }
            session.workingDirectory = workingDirectory
            self = .terminal(session)
            return true
        case .browser:
            return false
        case .horizontal(var children):
            for index in children.indices {
                if children[index].updateWorkingDirectory(workingDirectory, for: sessionID) {
                    self = .horizontal(children)
                    return true
                }
            }
            return false
        case .vertical(var children):
            for index in children.indices {
                if children[index].updateWorkingDirectory(workingDirectory, for: sessionID) {
                    self = .vertical(children)
                    return true
                }
            }
            return false
        }
    }

    @discardableResult
    public mutating func updateRecentText(_ recentText: String?, for sessionID: TerminalSessionID) -> Bool {
        switch self {
        case .terminal(var session):
            guard session.id == sessionID else { return false }
            session.recentText = TerminalSession.boundedRecentText(recentText)
            self = .terminal(session)
            return true
        case .browser:
            return false
        case .horizontal(var children):
            for index in children.indices {
                if children[index].updateRecentText(recentText, for: sessionID) {
                    self = .horizontal(children)
                    return true
                }
            }
            return false
        case .vertical(var children):
            for index in children.indices {
                if children[index].updateRecentText(recentText, for: sessionID) {
                    self = .vertical(children)
                    return true
                }
            }
            return false
        }
    }

    @discardableResult
    public mutating func updateBrowserURL(_ url: URL, for browserID: BrowserSessionID) -> Bool {
        switch self {
        case .browser(var session):
            guard session.id == browserID else { return false }
            session.url = url
            self = .browser(session)
            return true
        case .terminal:
            return false
        case .horizontal(var children):
            for index in children.indices where children[index].updateBrowserURL(url, for: browserID) {
                self = .horizontal(children)
                return true
            }
            return false
        case .vertical(var children):
            for index in children.indices where children[index].updateBrowserURL(url, for: browserID) {
                self = .vertical(children)
                return true
            }
            return false
        }
    }

    @discardableResult
    public mutating func updateBrowserDataProfile(
        _ profile: BrowserDataProfile?,
        for browserID: BrowserSessionID
    ) -> Bool {
        switch self {
        case .browser(var session):
            guard session.id == browserID else { return false }
            session.profile = profile
            self = .browser(session)
            return true
        case .terminal:
            return false
        case .horizontal(var children):
            for index in children.indices where children[index].updateBrowserDataProfile(profile, for: browserID) {
                self = .horizontal(children)
                return true
            }
            return false
        case .vertical(var children):
            for index in children.indices where children[index].updateBrowserDataProfile(profile, for: browserID) {
                self = .vertical(children)
                return true
            }
            return false
        }
    }

    @discardableResult
    public mutating func updateWorkingDirectory(
        _ workingDirectory: URL?,
        for paneID: PaneID
    ) -> Bool {
        guard let session = session(for: paneID) else { return false }
        return updateWorkingDirectory(workingDirectory, for: session.id)
    }

    public func removingTerminalSession(_ sessionID: TerminalSessionID) -> SplitNode? {
        guard contains(sessionID) else { return self }

        switch removing(sessionID) {
        case .notFound:
            return self
        case .removed(let node):
            return node
        }
    }

    public func removingPane(_ paneID: PaneID) -> SplitNode? {
        guard contains(paneID: paneID) else { return self }
        switch removing(paneID: paneID) {
        case .notFound: return self
        case .removed(let node): return node
        }
    }

    private enum RemovalResult {
        case notFound
        case removed(SplitNode?)
    }

    private func removing(_ sessionID: TerminalSessionID) -> RemovalResult {
        switch self {
        case .terminal(let session):
            return session.id == sessionID ? .removed(nil) : .notFound
        case .browser:
            return .notFound
        case .horizontal(let children):
            return removingFromBranch(children, orientation: .horizontal, sessionID: sessionID)
        case .vertical(let children):
            return removingFromBranch(children, orientation: .vertical, sessionID: sessionID)
        }
    }

    private func removing(paneID: PaneID) -> RemovalResult {
        switch self {
        case .terminal(let session):
            return session.paneID == paneID ? .removed(nil) : .notFound
        case .browser(let session):
            return session.paneID == paneID ? .removed(nil) : .notFound
        case .horizontal(let children):
            return removingFromBranch(children, orientation: .horizontal, paneID: paneID)
        case .vertical(let children):
            return removingFromBranch(children, orientation: .vertical, paneID: paneID)
        }
    }

    private func removingFromBranch(
        _ children: [SplitNode],
        orientation: SplitOrientation,
        paneID: PaneID
    ) -> RemovalResult {
        for index in children.indices {
            switch children[index].removing(paneID: paneID) {
            case .notFound:
                continue
            case .removed(let replacement):
                var remaining = children
                remaining.remove(at: index)
                if let replacement { remaining.insert(replacement, at: index) }
                return .removed(orientation.node(children: remaining).collapsed)
            }
        }
        return .notFound
    }

    private func removingFromBranch(
        _ children: [SplitNode],
        orientation: SplitOrientation,
        sessionID: TerminalSessionID
    ) -> RemovalResult {
        for index in children.indices {
            switch children[index].removing(sessionID) {
            case .notFound:
                continue
            case .removed(let replacement):
                var remaining = children
                remaining.remove(at: index)
                if let replacement {
                    remaining.insert(replacement, at: index)
                }
                return .removed(orientation.node(children: remaining).collapsed)
            }
        }
        return .notFound
    }

    private var collapsed: SplitNode? {
        switch self {
        case .terminal, .browser:
            return self
        case .horizontal(let children), .vertical(let children):
            switch children.count {
            case 0:
                return nil
            case 1:
                return children[0]
            default:
                return self
            }
        }
    }

    fileprivate func repaired(
        usedSessionIDs: inout Set<TerminalSessionID>,
        usedBrowserIDs: inout Set<BrowserSessionID>,
        usedPaneIDs: inout Set<PaneID>
    ) -> SplitNode? {
        switch self {
        case .terminal(let session):
            guard usedSessionIDs.insert(session.id).inserted,
                  usedPaneIDs.insert(session.paneID).inserted else { return nil }
            return self
        case .browser(let session):
            guard usedBrowserIDs.insert(session.id).inserted,
                  usedPaneIDs.insert(session.paneID).inserted else { return nil }
            return self
        case .horizontal(let children):
            let repairedChildren = children.compactMap {
                $0.repaired(usedSessionIDs: &usedSessionIDs, usedBrowserIDs: &usedBrowserIDs, usedPaneIDs: &usedPaneIDs)
            }
            return SplitOrientation.horizontal.node(children: repairedChildren).collapsed
        case .vertical(let children):
            let repairedChildren = children.compactMap {
                $0.repaired(usedSessionIDs: &usedSessionIDs, usedBrowserIDs: &usedBrowserIDs, usedPaneIDs: &usedPaneIDs)
            }
            return SplitOrientation.vertical.node(children: repairedChildren).collapsed
        }
    }

    private func paneLayouts() -> [PaneLayout] {
        paneLayouts(minX: 0, minY: 0, width: 1, height: 1)
    }

    private func paneLayouts(minX: Double, minY: Double, width: Double, height: Double) -> [PaneLayout] {
        switch self {
        case .terminal(let session):
            return [PaneLayout(sessionID: session.id, paneID: session.paneID, minX: minX, minY: minY, width: width, height: height)]
        case .browser(let session):
            return [PaneLayout(sessionID: nil, paneID: session.paneID, minX: minX, minY: minY, width: width, height: height)]
        case .horizontal(let children):
            guard !children.isEmpty else { return [] }
            let childWidth = width / Double(children.count)
            return children.enumerated().flatMap { index, child in
                child.paneLayouts(
                    minX: minX + (Double(index) * childWidth),
                    minY: minY,
                    width: childWidth,
                    height: height
                )
            }
        case .vertical(let children):
            guard !children.isEmpty else { return [] }
            let childHeight = height / Double(children.count)
            return children.enumerated().flatMap { index, child in
                child.paneLayouts(
                    minX: minX,
                    minY: minY + (Double(index) * childHeight),
                    width: width,
                    height: childHeight
                )
            }
        }
    }
}

public struct SplitPaneLayout: Equatable, Hashable, Sendable, Identifiable {
    public let sessionID: TerminalSessionID
    public let paneID: PaneID
    public let nodeID: SplitNodeID
    public let minX: Double
    public let minY: Double
    public let width: Double
    public let height: Double
    public var id: PaneID { paneID }
    public var maxX: Double { minX + width }
    public var maxY: Double { minY + height }

    fileprivate init?(_ layout: PaneLayout) {
        guard let sessionID = layout.sessionID else { return nil }
        self.sessionID = sessionID
        paneID = layout.paneID
        nodeID = SplitNodeID(rawValue: layout.paneID.rawValue)
        minX = layout.minX; minY = layout.minY; width = layout.width; height = layout.height
    }
}

fileprivate struct PaneLayout {
    static let epsilon = 0.000_001

    let sessionID: TerminalSessionID?
    let paneID: PaneID
    let minX: Double
    let minY: Double
    let width: Double
    let height: Double

    var maxX: Double { minX + width }
    var maxY: Double { minY + height }
    var centerX: Double { minX + (width / 2) }
    var centerY: Double { minY + (height / 2) }
}

private extension SplitOrientation {
    func node(children: [SplitNode]) -> SplitNode {
        switch self {
        case .horizontal:
            return .horizontal(children)
        case .vertical:
            return .vertical(children)
        }
    }
}

public enum TabContent: Codable, Equatable, Hashable, Sendable {
    case terminal(SplitNode)
    case browser(BrowserSession)

    private enum CodingKeys: String, CodingKey {
        case type
        case splitTree
        case session
    }

    private enum ContentType: String, Codable {
        case terminal
        case browser
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ContentType.self, forKey: .type) {
        case .terminal:
            self = .terminal(try container.decode(SplitNode.self, forKey: .splitTree))
        case .browser:
            self = .browser(try container.decode(BrowserSession.self, forKey: .session))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal(let tree):
            try container.encode(ContentType.terminal, forKey: .type)
            try container.encode(tree, forKey: .splitTree)
        case .browser(let session):
            try container.encode(ContentType.browser, forKey: .type)
            try container.encode(session, forKey: .session)
        }
    }
}

public struct Tab: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: TabID
    public var content: TabContent
    public var focusedTerminalSessionID: TerminalSessionID?
    public var focusedPaneID: PaneID?
    public var customTitle: String?

    public init(
        id: TabID = TabID(),
        content: TabContent,
        focusedTerminalSessionID: TerminalSessionID? = nil,
        focusedPaneID: PaneID? = nil,
        customTitle: String? = nil
    ) {
        self.id = id
        self.content = content
        self.focusedTerminalSessionID = focusedTerminalSessionID
        self.focusedPaneID = focusedPaneID
        self.customTitle = customTitle
        repair()
    }

    public static func terminal(
        id: TabID = TabID(),
        workingDirectory: URL? = nil
    ) -> Tab {
        let session = TerminalSession(workingDirectory: workingDirectory)
        return Tab(
            id: id,
            content: .terminal(.terminal(session)),
            focusedTerminalSessionID: session.id,
            focusedPaneID: session.paneID
        )
    }

    public static func browser(
        id: TabID = TabID(),
        url: URL,
        profile: BrowserDataProfile? = nil
    ) -> Tab {
        let session = BrowserSession(url: url, profile: profile)
        return Tab(id: id, content: .browser(session), focusedPaneID: session.paneID)
    }

    public var isBrowser: Bool {
        focusedBrowserSession != nil
    }

    public var splitTree: SplitNode {
        switch content {
        case .terminal(let tree): return tree
        case .browser(let session): return .browser(session)
        }
    }

    public var focusedBrowserSession: BrowserSession? {
        guard let focusedPaneID else { return nil }
        return splitTree.browser(for: focusedPaneID)
    }

    public var terminalTree: SplitNode? {
        get {
            guard case .terminal(let tree) = content else { return nil }
            return tree
        }
        set {
            guard let newValue else { return }
            content = .terminal(newValue)
            repair()
        }
    }

    internal mutating func repair() {
        guard case .terminal(let tree) = content else {
            focusedTerminalSessionID = nil
            if case .browser(let browser) = content {
                focusedPaneID = browser.paneID
            }
            return
        }

        var usedIDs = Set<TerminalSessionID>()
        var usedBrowserIDs = Set<BrowserSessionID>()
        var usedPaneIDs = Set<PaneID>()
        guard let repairedTree = tree.repaired(
            usedSessionIDs: &usedIDs,
            usedBrowserIDs: &usedBrowserIDs,
            usedPaneIDs: &usedPaneIDs
        ) else {
            content = .terminal(.terminal(TerminalSession()))
            focusedTerminalSessionID = terminalTree?.terminalSessionIDs.first
            focusedPaneID = terminalTree?.paneIDs.first
            return
        }
        content = .terminal(repairedTree)
        if focusedPaneID.map({ repairedTree.contains(paneID: $0) }) != true {
            if let focusedTerminalSessionID,
               let session = repairedTree.terminalSessions.first(where: { $0.id == focusedTerminalSessionID }) {
                focusedPaneID = session.paneID
            } else {
                focusedPaneID = repairedTree.paneIDs.first
            }
        }
        focusedTerminalSessionID = focusedPaneID.flatMap { repairedTree.session(for: $0)?.id }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case content
        case focusedTerminalSessionID
        case focusedPaneID
        case customTitle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TabID.self, forKey: .id)
        content = try container.decode(TabContent.self, forKey: .content)
        do {
            focusedTerminalSessionID = try container.decodeIfPresent(
                TerminalSessionID.self,
                forKey: .focusedTerminalSessionID
            )
        } catch {
            focusedTerminalSessionID = nil
        }
        focusedPaneID = try? container.decodeIfPresent(PaneID.self, forKey: .focusedPaneID)
        customTitle = try? container.decodeIfPresent(String.self, forKey: .customTitle)
        repair()
    }
}

public enum WorkspaceColor: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case red
    case orange
    case yellow
    case green
    case teal
    case blue
    case indigo
    case purple
    case pink
    case gray
}

public typealias WorkspaceFolderColor = WorkspaceColor

public struct WorkspaceFolder: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: WorkspaceFolderID
    public var title: String
    public var color: WorkspaceFolderColor
    public var isExpanded: Bool
    public var settingsOverrides: TerminalPreferencesOverrides?

    public init(
        id: WorkspaceFolderID = WorkspaceFolderID(),
        title: String,
        color: WorkspaceFolderColor = .blue,
        isExpanded: Bool = true,
        settingsOverrides: TerminalPreferencesOverrides? = nil
    ) {
        self.id = id
        self.title = title
        self.color = color
        self.isExpanded = isExpanded
        self.settingsOverrides = settingsOverrides
    }
}

public struct Workspace: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: WorkspaceID
    public var title: String
    public var emoji: String?
    public var color: WorkspaceColor?
    public var tabs: [Tab]
    public var selectedTabID: TabID?
    public var folderID: WorkspaceFolderID?
    public var isPinned: Bool
    public var settingsOverrides: TerminalPreferencesOverrides?

    public init(
        id: WorkspaceID = WorkspaceID(),
        title: String,
        emoji: String? = nil,
        color: WorkspaceColor? = nil,
        tabs: [Tab] = [],
        selectedTabID: TabID? = nil,
        folderID: WorkspaceFolderID? = nil,
        isPinned: Bool = false,
        settingsOverrides: TerminalPreferencesOverrides? = nil
    ) {
        self.id = id
        self.title = title
        self.emoji = emoji
        self.color = color
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.folderID = folderID
        self.isPinned = isPinned
        self.settingsOverrides = settingsOverrides
        repair()
    }

    public init(
        id: WorkspaceID = WorkspaceID(),
        title: String,
        emoji: String? = nil,
        color: WorkspaceColor? = nil,
        folderID: WorkspaceFolderID? = nil,
        isPinned: Bool = false,
        settingsOverrides: TerminalPreferencesOverrides? = nil
    ) {
        let tab = Tab.terminal()
        self.init(
            id: id,
            title: title,
            emoji: emoji,
            color: color,
            tabs: [tab],
            selectedTabID: tab.id,
            folderID: folderID,
            isPinned: isPinned,
            settingsOverrides: settingsOverrides
        )
    }

    public var selectedTab: Tab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    public var displayTitle: String {
        guard let emoji, !emoji.isEmpty else { return title }
        return "\(emoji) \(title)"
    }

    internal mutating func repair() {
        var seenTabIDs = Set<TabID>()
        tabs = tabs.compactMap { tab in
            guard seenTabIDs.insert(tab.id).inserted else { return nil }
            var repairedTab = tab
            repairedTab.repair()
            return repairedTab
        }
        if let selectedTabID, tabs.contains(where: { $0.id == selectedTabID }) {
            self.selectedTabID = selectedTabID
        } else {
            self.selectedTabID = tabs.first?.id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case emoji
        case color
        case tabs
        case selectedTabID
        case folderID
        case isPinned
        case settingsOverrides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(WorkspaceID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        emoji = try? container.decodeIfPresent(String.self, forKey: .emoji)
        color = try? container.decodeIfPresent(WorkspaceColor.self, forKey: .color)
        tabs = try container.decodeIfPresent(LossyArray<Tab>.self, forKey: .tabs)?.elements ?? []
        do {
            selectedTabID = try container.decodeIfPresent(TabID.self, forKey: .selectedTabID)
        } catch {
            selectedTabID = nil
        }
        folderID = try? container.decodeIfPresent(WorkspaceFolderID.self, forKey: .folderID)
        isPinned = (try? container.decodeIfPresent(Bool.self, forKey: .isPinned)) ?? false
        settingsOverrides = try? container.decodeIfPresent(TerminalPreferencesOverrides.self, forKey: .settingsOverrides)
        repair()
    }
}

internal struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Element] = []
        while !container.isAtEnd {
            do {
                values.append(try container.decode(Element.self))
            } catch {
                _ = try container.superDecoder()
            }
        }
        elements = values
    }
}
