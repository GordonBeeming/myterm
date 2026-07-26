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
        paneID = try container.decodeIfPresent(PaneID.self, forKey: .paneID)
            ?? PaneID(rawValue: repairedUUID(seed: "terminal:\(id):missing-pane"))
        workingDirectory = try container.decodeIfPresent(URL.self, forKey: .workingDirectory)
        recentText = Self.boundedRecentText(try? container.decodeIfPresent(String.self, forKey: .recentText))
    }

    public static func boundedRecentText(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        var bounded = value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maximumRecentTextLines)
            .joined(separator: "\n")
        while bounded.lengthOfBytes(using: .utf8) > maximumRecentTextBytes, !bounded.isEmpty {
            bounded.removeFirst()
        }
        return bounded.isEmpty ? nil : bounded
    }
}

public enum BrowserDataScope: String, Codable, Equatable, Hashable, Sendable {
    case appWide = "app-wide"
    case folder
    case workspace
    case projectDirectory = "project-directory"
}

public struct BrowserDataProfile: Codable, Equatable, Hashable, Sendable {
    public let scope: BrowserDataScope
    public let persistentStoreID: UUID
    public let projectDirectory: URL?

    public init(scope: BrowserDataScope, persistentStoreID: UUID, projectDirectory: URL? = nil) {
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
        paneID = try container.decodeIfPresent(PaneID.self, forKey: .paneID)
            ?? PaneID(rawValue: repairedUUID(seed: "browser:\(id):missing-pane"))
        url = try container.decode(URL.self, forKey: .url)
        profile = try container.decodeIfPresent(BrowserDataProfile.self, forKey: .profile)
    }
}

public enum SplitOrientation: String, Codable, Equatable, Hashable, Sendable {
    case horizontal
    case vertical
}

public enum PaneFocusDirection: Equatable, Sendable {
    case left
    case up
    case right
    case down
}

public enum PaneEdge: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case left
    case top
    case right
    case bottom

    public var orientation: SplitOrientation {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        }
    }

    fileprivate var insertsBefore: Bool {
        self == .left || self == .top
    }
}

public enum TabContent: Codable, Equatable, Hashable, Sendable {
    case terminal(TerminalSession)
    case browser(BrowserSession)

    private enum CodingKeys: String, CodingKey {
        case type
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
            self = .terminal(try container.decode(TerminalSession.self, forKey: .session))
        case .browser:
            self = .browser(try container.decode(BrowserSession.self, forKey: .session))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal(let session):
            try container.encode(ContentType.terminal, forKey: .type)
            try container.encode(session, forKey: .session)
        case .browser(let session):
            try container.encode(ContentType.browser, forKey: .type)
            try container.encode(session, forKey: .session)
        }
    }
}

public struct Tab: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: TabID
    public var content: TabContent
    public var customTitle: String?

    public init(id: TabID = TabID(), content: TabContent, customTitle: String? = nil) {
        self.id = id
        self.content = content
        self.customTitle = customTitle
    }

    public static func terminal(
        id: TabID = TabID(),
        workingDirectory: URL? = nil,
        customTitle: String? = nil
    ) -> Tab {
        Tab(id: id, content: .terminal(TerminalSession(workingDirectory: workingDirectory)), customTitle: customTitle)
    }

    public static func browser(
        id: TabID = TabID(),
        url: URL,
        profile: BrowserDataProfile? = nil,
        customTitle: String? = nil
    ) -> Tab {
        Tab(id: id, content: .browser(BrowserSession(url: url, profile: profile)), customTitle: customTitle)
    }

    public var terminalSession: TerminalSession? {
        guard case .terminal(let session) = content else { return nil }
        return session
    }

    public var browserSession: BrowserSession? {
        guard case .browser(let session) = content else { return nil }
        return session
    }

    public var isBrowser: Bool { browserSession != nil }
    public var paneID: PaneID {
        switch content {
        case .terminal(let session): session.paneID
        case .browser(let session): session.paneID
        }
    }

    // Transitional read-only conveniences. Focus now belongs to the containing tab group.
    public var focusedTerminalSessionID: TerminalSessionID? { terminalSession?.id }
    public var focusedPaneID: PaneID? { paneID }
    public var focusedBrowserSession: BrowserSession? { browserSession }
}

public struct TabGroup: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: TabGroupID
    public internal(set) var tabs: [Tab]
    public internal(set) var selectedTabID: TabID

    public init(id: TabGroupID = TabGroupID(), tabs: [Tab], selectedTabID: TabID? = nil) {
        self.id = id
        if tabs.isEmpty {
            let tab = Tab(
                id: TabID(rawValue: repairedUUID(seed: "tab-group:\(id):fallback-tab")),
                content: .terminal(TerminalSession(
                    id: TerminalSessionID(rawValue: repairedUUID(seed: "tab-group:\(id):fallback-terminal")),
                    paneID: PaneID(rawValue: repairedUUID(seed: "tab-group:\(id):fallback-pane"))
                ))
            )
            self.tabs = [tab]
            self.selectedTabID = tab.id
        } else {
            self.tabs = tabs
            self.selectedTabID = selectedTabID.flatMap { selected in
                tabs.contains(where: { $0.id == selected }) ? selected : nil
            } ?? tabs[0].id
        }
    }

    public init(id: TabGroupID = TabGroupID(), tab: Tab = .terminal()) {
        self.init(id: id, tabs: [tab], selectedTabID: tab.id)
    }

    public var selectedTab: Tab {
        tabs.first(where: { $0.id == selectedTabID }) ?? tabs[0]
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case tabs
        case selectedTabID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(TabGroupID.self, forKey: .id)
        let tabs = try container.decodeIfPresent(LossyArray<Tab>.self, forKey: .tabs)?.elements ?? []
        let selectedTabID = try? container.decodeIfPresent(TabID.self, forKey: .selectedTabID)
        self.init(id: id, tabs: tabs, selectedTabID: selectedTabID)
    }
}

public indirect enum WorkspaceLayout: Codable, Equatable, Hashable, Sendable {
    case group(TabGroup)
    case split(id: SplitNodeID, orientation: SplitOrientation, children: [WorkspaceLayout], weights: [Double])

    private enum CodingKeys: String, CodingKey {
        case type
        case group
        case id
        case orientation
        case children
        case weights
    }

    private enum NodeType: String, Codable {
        case group
        case split
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(NodeType.self, forKey: .type) {
        case .group:
            self = .group(try container.decode(TabGroup.self, forKey: .group))
        case .split:
            let id = try container.decode(SplitNodeID.self, forKey: .id)
            let orientation = try container.decode(SplitOrientation.self, forKey: .orientation)
            let children = try container.decodeIfPresent(LossyArray<WorkspaceLayout>.self, forKey: .children)?.elements ?? []
            let weights = (try? container.decode([Double].self, forKey: .weights)) ?? []
            self = .split(
                id: id,
                orientation: orientation,
                children: children,
                weights: Self.normalizedWeights(weights, count: children.count)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .group(let group):
            try container.encode(NodeType.group, forKey: .type)
            try container.encode(group, forKey: .group)
        case .split(let id, let orientation, let children, let weights):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(orientation, forKey: .orientation)
            try container.encode(children, forKey: .children)
            try container.encode(Self.normalizedWeights(weights, count: children.count), forKey: .weights)
        }
    }

    public static func split(
        orientation: SplitOrientation,
        children: [WorkspaceLayout],
        weights: [Double] = []
    ) -> WorkspaceLayout {
        .split(
            id: SplitNodeID(),
            orientation: orientation,
            children: children,
            weights: normalizedWeights(weights, count: children.count)
        )
    }

    public static func normalizedWeights(_ weights: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard weights.count == count,
              weights.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return Array(repeating: 1 / Double(count), count: count)
        }
        let total = weights.reduce(0, +)
        guard total.isFinite, total > 0 else {
            return Array(repeating: 1 / Double(count), count: count)
        }
        return weights.map { $0 / total }
    }

    public var orderedGroups: [TabGroup] {
        switch self {
        case .group(let group): [group]
        case .split(_, _, let children, _): children.flatMap(\.orderedGroups)
        }
    }

    public var splitNodeIDs: [SplitNodeID] {
        switch self {
        case .group: []
        case .split(let id, _, let children, _): [id] + children.flatMap(\.splitNodeIDs)
        }
    }

    public func group(id: TabGroupID) -> TabGroup? {
        switch self {
        case .group(let group): group.id == id ? group : nil
        case .split(_, _, let children, _): children.lazy.compactMap { $0.group(id: id) }.first
        }
    }

    @discardableResult
    internal mutating func replaceGroup(id: TabGroupID, with replacement: TabGroup) -> Bool {
        switch self {
        case .group(let group):
            guard group.id == id else { return false }
            self = .group(replacement)
            return true
        case .split(let splitID, let orientation, var children, let weights):
            for index in children.indices where children[index].replaceGroup(id: id, with: replacement) {
                self = .split(id: splitID, orientation: orientation, children: children, weights: weights)
                return true
            }
            return false
        }
    }

    @discardableResult
    internal mutating func insertGroup(_ group: TabGroup, beside targetID: TabGroupID, edge: PaneEdge) -> Bool {
        switch self {
        case .group(let target):
            guard target.id == targetID else { return false }
            let nodes: [WorkspaceLayout] = edge.insertsBefore
                ? [.group(group), .group(target)]
                : [.group(target), .group(group)]
            self = .split(orientation: edge.orientation, children: nodes)
            return true
        case .split(let splitID, let orientation, var children, let weights):
            for index in children.indices where children[index].insertGroup(group, beside: targetID, edge: edge) {
                self = .split(id: splitID, orientation: orientation, children: children, weights: weights)
                return true
            }
            return false
        }
    }

    internal func removingGroup(id groupID: TabGroupID) -> WorkspaceLayout? {
        switch self {
        case .group(let group):
            return group.id == groupID ? nil : self
        case .split(let splitID, let orientation, let children, let weights):
            guard children.contains(where: { $0.group(id: groupID) != nil }) else { return self }
            var repairedChildren: [WorkspaceLayout] = []
            var retainedWeights: [Double] = []
            for (index, child) in children.enumerated() {
                if let retained = child.removingGroup(id: groupID) {
                    repairedChildren.append(retained)
                    retainedWeights.append(index < weights.count ? weights[index] : 0)
                }
            }
            switch repairedChildren.count {
            case 0: return nil
            case 1: return repairedChildren[0]
            default:
                return .split(
                    id: splitID,
                    orientation: orientation,
                    children: repairedChildren,
                    weights: Self.normalizedWeights(retainedWeights, count: repairedChildren.count)
                )
            }
        }
    }

    @discardableResult
    internal mutating func updateWeights(splitID: SplitNodeID, weights newWeights: [Double]) -> Bool {
        switch self {
        case .group:
            return false
        case .split(let id, let orientation, var children, let weights):
            if id == splitID {
                self = .split(
                    id: id,
                    orientation: orientation,
                    children: children,
                    weights: Self.normalizedWeights(newWeights, count: children.count)
                )
                return true
            }
            for index in children.indices where children[index].updateWeights(splitID: splitID, weights: newWeights) {
                self = .split(id: id, orientation: orientation, children: children, weights: weights)
                return true
            }
            return false
        }
    }

    fileprivate func groupFrames() -> [GroupFrame] {
        groupFrames(minX: 0, minY: 0, width: 1, height: 1)
    }

    private func groupFrames(minX: Double, minY: Double, width: Double, height: Double) -> [GroupFrame] {
        switch self {
        case .group(let group):
            return [GroupFrame(groupID: group.id, minX: minX, minY: minY, width: width, height: height)]
        case .split(_, let orientation, let children, let weights):
            let normalized = Self.normalizedWeights(weights, count: children.count)
            var offset = 0.0
            return children.enumerated().flatMap { index, child -> [GroupFrame] in
                let proportion = normalized[index]
                defer { offset += proportion }
                switch orientation {
                case .horizontal:
                    return child.groupFrames(
                        minX: minX + (width * offset),
                        minY: minY,
                        width: width * proportion,
                        height: height
                    )
                case .vertical:
                    return child.groupFrames(
                        minX: minX,
                        minY: minY + (height * offset),
                        width: width,
                        height: height * proportion
                    )
                }
            }
        }
    }

    fileprivate func repaired(
        seed: String,
        tracker: RecoveryDecodingTracker? = nil,
        usedGroupIDs: inout Set<TabGroupID>,
        usedTabIDs: inout Set<TabID>,
        usedTerminalIDs: inout Set<TerminalSessionID>,
        usedBrowserIDs: inout Set<BrowserSessionID>,
        usedPaneIDs: inout Set<PaneID>,
        usedSplitIDs: inout Set<SplitNodeID>
    ) -> WorkspaceLayout? {
        switch self {
        case .group(let group):
            return .group(group.repaired(
                seed: seed,
                tracker: tracker,
                usedGroupIDs: &usedGroupIDs,
                usedTabIDs: &usedTabIDs,
                usedTerminalIDs: &usedTerminalIDs,
                usedBrowserIDs: &usedBrowserIDs,
                usedPaneIDs: &usedPaneIDs
            ))
        case .split(let id, let orientation, let children, let weights):
            let repairedID = uniqueIdentifier(
                id,
                used: &usedSplitIDs,
                seed: "\(seed):split",
                make: SplitNodeID.init(rawValue:),
                tracker: tracker
            )
            var repairedChildren: [WorkspaceLayout] = []
            var retainedWeights: [Double] = []
            for (index, child) in children.enumerated() {
                if let repaired = child.repaired(
                    seed: "\(seed):\(index)",
                    tracker: tracker,
                    usedGroupIDs: &usedGroupIDs,
                    usedTabIDs: &usedTabIDs,
                    usedTerminalIDs: &usedTerminalIDs,
                    usedBrowserIDs: &usedBrowserIDs,
                    usedPaneIDs: &usedPaneIDs,
                    usedSplitIDs: &usedSplitIDs
                ) {
                    repairedChildren.append(repaired)
                    retainedWeights.append(index < weights.count ? weights[index] : 0)
                }
            }
            switch repairedChildren.count {
            case 0: return nil
            case 1: return repairedChildren[0]
            default:
                return .split(
                    id: repairedID,
                    orientation: orientation,
                    children: repairedChildren,
                    weights: Self.normalizedWeights(retainedWeights, count: repairedChildren.count)
                )
            }
        }
    }
}

private struct GroupFrame {
    static let epsilon = 0.000_001

    let groupID: TabGroupID
    let minX: Double
    let minY: Double
    let width: Double
    let height: Double

    var maxX: Double { minX + width }
    var maxY: Double { minY + height }
    var centerX: Double { minX + width / 2 }
    var centerY: Double { minY + height / 2 }
}

private extension TabGroup {
    func repaired(
        seed: String,
        tracker: RecoveryDecodingTracker? = nil,
        usedGroupIDs: inout Set<TabGroupID>,
        usedTabIDs: inout Set<TabID>,
        usedTerminalIDs: inout Set<TerminalSessionID>,
        usedBrowserIDs: inout Set<BrowserSessionID>,
        usedPaneIDs: inout Set<PaneID>
    ) -> TabGroup {
        let groupID = uniqueIdentifier(
            id,
            used: &usedGroupIDs,
            seed: "\(seed):group",
            make: TabGroupID.init(rawValue:),
            tracker: tracker
        )
        let sourceTabs = tabs.isEmpty ? [Tab.terminal()] : tabs
        let repairedTabs = sourceTabs.enumerated().map { index, tab -> Tab in
            let tabID = uniqueIdentifier(
                tab.id,
                used: &usedTabIDs,
                seed: "\(seed):tab:\(index)",
                make: TabID.init(rawValue:),
                tracker: tracker
            )
            switch tab.content {
            case .terminal(let session):
                let sessionID = uniqueIdentifier(
                    session.id,
                    used: &usedTerminalIDs,
                    seed: "\(seed):terminal:\(index)",
                    make: TerminalSessionID.init(rawValue:),
                    tracker: tracker
                )
                let paneID = uniqueIdentifier(
                    session.paneID,
                    used: &usedPaneIDs,
                    seed: "\(seed):pane:\(index)",
                    make: PaneID.init(rawValue:),
                    tracker: tracker
                )
                return Tab(
                    id: tabID,
                    content: .terminal(TerminalSession(
                        id: sessionID,
                        paneID: paneID,
                        workingDirectory: session.workingDirectory,
                        recentText: session.recentText
                    )),
                    customTitle: tab.customTitle
                )
            case .browser(let session):
                let browserID = uniqueIdentifier(
                    session.id,
                    used: &usedBrowserIDs,
                    seed: "\(seed):browser:\(index)",
                    make: BrowserSessionID.init(rawValue:),
                    tracker: tracker
                )
                let paneID = uniqueIdentifier(
                    session.paneID,
                    used: &usedPaneIDs,
                    seed: "\(seed):pane:\(index)",
                    make: PaneID.init(rawValue:),
                    tracker: tracker
                )
                return Tab(
                    id: tabID,
                    content: .browser(BrowserSession(
                        id: browserID,
                        paneID: paneID,
                        url: session.url,
                        profile: session.profile
                    )),
                    customTitle: tab.customTitle
                )
            }
        }
        let selected = repairedTabs.firstIndex(where: { $0.id == selectedTabID }).map { repairedTabs[$0].id }
            ?? tabs.firstIndex(where: { $0.id == selectedTabID }).map { repairedTabs[$0].id }
            ?? repairedTabs[0].id
        return TabGroup(id: groupID, tabs: repairedTabs, selectedTabID: selected)
    }
}

internal func uniqueIdentifier<ID: Hashable>(
    _ proposed: ID,
    used: inout Set<ID>,
    seed: String,
    make: (UUID) -> ID,
    tracker: RecoveryDecodingTracker? = nil
) -> ID {
    if used.insert(proposed).inserted { return proposed }
    tracker?.recordIdentifierRepair()
    var ordinal = 0
    while true {
        let replacement = make(repairedUUID(seed: "\(seed):\(ordinal)"))
        if used.insert(replacement).inserted { return replacement }
        ordinal += 1
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
    public var layout: WorkspaceLayout
    public var focusedTabGroupID: TabGroupID
    public var folderID: WorkspaceFolderID?
    public var isPinned: Bool
    public var settingsOverrides: TerminalPreferencesOverrides?

    public init(
        id: WorkspaceID = WorkspaceID(),
        title: String,
        emoji: String? = nil,
        color: WorkspaceColor? = nil,
        layout: WorkspaceLayout,
        focusedTabGroupID: TabGroupID? = nil,
        folderID: WorkspaceFolderID? = nil,
        isPinned: Bool = false,
        settingsOverrides: TerminalPreferencesOverrides? = nil
    ) {
        self.id = id
        self.title = title
        self.emoji = emoji
        self.color = color
        self.layout = layout
        self.focusedTabGroupID = focusedTabGroupID ?? layout.orderedGroups.first?.id ?? TabGroupID()
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
        let group = TabGroup(tab: .terminal())
        self.init(
            id: id,
            title: title,
            emoji: emoji,
            color: color,
            layout: .group(group),
            focusedTabGroupID: group.id,
            folderID: folderID,
            isPinned: isPinned,
            settingsOverrides: settingsOverrides
        )
    }

    // Source compatibility for callers constructing a single pane. The persisted owner remains a TabGroup.
    public init(
        id: WorkspaceID = WorkspaceID(),
        title: String,
        emoji: String? = nil,
        color: WorkspaceColor? = nil,
        tabs: [Tab],
        selectedTabID: TabID? = nil,
        folderID: WorkspaceFolderID? = nil,
        isPinned: Bool = false,
        settingsOverrides: TerminalPreferencesOverrides? = nil
    ) {
        let group = TabGroup(tabs: tabs, selectedTabID: selectedTabID)
        self.init(
            id: id,
            title: title,
            emoji: emoji,
            color: color,
            layout: .group(group),
            focusedTabGroupID: group.id,
            folderID: folderID,
            isPinned: isPinned,
            settingsOverrides: settingsOverrides
        )
    }

    public var orderedGroups: [TabGroup] { layout.orderedGroups }
    public var focusedTabGroup: TabGroup? { layout.group(id: focusedTabGroupID) }
    public var selectedTab: Tab? { focusedTabGroup?.selectedTab }
    public var selectedTabID: TabID? { focusedTabGroup?.selectedTabID }
    public var tabs: [Tab] { focusedTabGroup?.tabs ?? [] }
    public var allTabs: [Tab] { orderedGroups.flatMap(\.tabs) }
    public var terminalSessions: [TerminalSession] { allTabs.compactMap(\.terminalSession) }
    public var browserSessions: [BrowserSession] { allTabs.compactMap(\.browserSession) }

    public var displayTitle: String {
        guard let emoji, !emoji.isEmpty else { return title }
        return "\(emoji) \(title)"
    }

    public func group(id: TabGroupID) -> TabGroup? { layout.group(id: id) }

    public func groupID(containing tabID: TabID) -> TabGroupID? {
        orderedGroups.first(where: { $0.tabs.contains(where: { $0.id == tabID }) })?.id
    }

    public func groupID(containing paneID: PaneID) -> TabGroupID? {
        orderedGroups.first(where: { $0.tabs.contains(where: { $0.paneID == paneID }) })?.id
    }

    public func tab(groupID: TabGroupID, tabID: TabID) -> Tab? {
        group(id: groupID)?.tabs.first(where: { $0.id == tabID })
    }

    public func tab(id tabID: TabID) -> Tab? {
        allTabs.first(where: { $0.id == tabID })
    }

    public func terminalSession(id sessionID: TerminalSessionID) -> TerminalSession? {
        terminalSessions.first(where: { $0.id == sessionID })
    }

    public func browserSession(id browserID: BrowserSessionID) -> BrowserSession? {
        browserSessions.first(where: { $0.id == browserID })
    }

    public func adjacentTabGroupID(to groupID: TabGroupID, direction: PaneFocusDirection) -> TabGroupID? {
        let frames = layout.groupFrames()
        guard let source = frames.first(where: { $0.groupID == groupID }) else { return nil }
        return frames
            .filter { $0.groupID != groupID }
            .compactMap { candidate -> (frame: GroupFrame, primary: Double, secondary: Double)? in
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
                guard primary >= -GroupFrame.epsilon, overlap > GroupFrame.epsilon else { return nil }
                return (candidate, max(primary, 0), secondary)
            }
            .min {
                if abs($0.primary - $1.primary) > GroupFrame.epsilon {
                    return $0.primary < $1.primary
                }
                return $0.secondary < $1.secondary
            }?
            .frame.groupID
    }

    internal mutating func repair(tracker: RecoveryDecodingTracker? = nil) {
        var usedGroupIDs = Set<TabGroupID>()
        var usedTabIDs = Set<TabID>()
        var usedTerminalIDs = Set<TerminalSessionID>()
        var usedBrowserIDs = Set<BrowserSessionID>()
        var usedPaneIDs = Set<PaneID>()
        var usedSplitIDs = Set<SplitNodeID>()
        repair(
            usedGroupIDs: &usedGroupIDs,
            usedTabIDs: &usedTabIDs,
            usedTerminalIDs: &usedTerminalIDs,
            usedBrowserIDs: &usedBrowserIDs,
            usedPaneIDs: &usedPaneIDs,
            usedSplitIDs: &usedSplitIDs,
            tracker: tracker
        )
    }

    internal mutating func repair(
        usedGroupIDs: inout Set<TabGroupID>,
        usedTabIDs: inout Set<TabID>,
        usedTerminalIDs: inout Set<TerminalSessionID>,
        usedBrowserIDs: inout Set<BrowserSessionID>,
        usedPaneIDs: inout Set<PaneID>,
        usedSplitIDs: inout Set<SplitNodeID>,
        tracker: RecoveryDecodingTracker? = nil
    ) {
        layout = layout.repaired(
            seed: "workspace:\(id)",
            tracker: tracker,
            usedGroupIDs: &usedGroupIDs,
            usedTabIDs: &usedTabIDs,
            usedTerminalIDs: &usedTerminalIDs,
            usedBrowserIDs: &usedBrowserIDs,
            usedPaneIDs: &usedPaneIDs,
            usedSplitIDs: &usedSplitIDs
        ) ?? {
            let groupID = uniqueIdentifier(
                TabGroupID(rawValue: repairedUUID(seed: "workspace:\(id):fallback-group")),
                used: &usedGroupIDs,
                seed: "workspace:\(id):fallback-group",
                make: TabGroupID.init(rawValue:),
                tracker: tracker
            )
            return .group(TabGroup(id: groupID, tabs: []))
        }()
        if layout.group(id: focusedTabGroupID) == nil {
            focusedTabGroupID = layout.orderedGroups[0].id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case emoji
        case color
        case layout
        case focusedTabGroupID
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
        layout = try container.decode(WorkspaceLayout.self, forKey: .layout)
        focusedTabGroupID = (try? container.decode(TabGroupID.self, forKey: .focusedTabGroupID))
            ?? layout.orderedGroups.first?.id
            ?? TabGroupID(rawValue: repairedUUID(seed: "workspace:\(id):missing-focused-group"))
        folderID = try? container.decodeIfPresent(WorkspaceFolderID.self, forKey: .folderID)
        isPinned = (try? container.decodeIfPresent(Bool.self, forKey: .isPinned)) ?? false
        settingsOverrides = try? container.decodeIfPresent(TerminalPreferencesOverrides.self, forKey: .settingsOverrides)
        repair(tracker: decoder.userInfo[.recoveryDecodingTracker] as? RecoveryDecodingTracker)
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
                (decoder.userInfo[.recoveryDecodingTracker] as? RecoveryDecodingTracker)?.recordDroppedElement()
                _ = try? container.superDecoder()
            }
        }
        elements = values
    }
}

internal final class RecoveryDecodingTracker: @unchecked Sendable {
    private(set) var droppedElementCount = 0
    private(set) var identifierRepairCount = 0
    private(set) var structuralRepairCount = 0

    func recordDroppedElement() {
        droppedElementCount += 1
    }

    func recordIdentifierRepair() {
        identifierRepairCount += 1
    }

    func recordStructuralRepairs(_ count: Int) {
        structuralRepairCount += count
    }
}

internal extension CodingUserInfoKey {
    static let recoveryDecodingTracker: CodingUserInfoKey = {
        guard let key = CodingUserInfoKey(rawValue: "net.gordonbeeming.myterm.recovery-decoding-tracker") else {
            preconditionFailure("The recovery decoding tracker key must be valid.")
        }
        return key
    }()
}
