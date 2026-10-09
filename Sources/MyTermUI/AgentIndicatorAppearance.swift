import MyTermCore
import SwiftUI

public struct AgentIndicatorAppearance: Equatable, Sendable {
    public var workingIcon: WorkingIndicatorIcon
    public var workingColor: WorkspaceColor
    public var finishedIcon: FinishedIndicatorIcon
    public var finishedColor: WorkspaceColor
    public var questionIcon: QuestionIndicatorIcon
    public var questionColor: WorkspaceColor

    public init(preferences: TerminalPreferences = .default) {
        workingIcon = preferences.workingIndicatorIcon
        workingColor = preferences.workingIndicatorColor
        finishedIcon = preferences.finishedIndicatorIcon
        finishedColor = preferences.finishedIndicatorColor
        questionIcon = preferences.questionIndicatorIcon
        questionColor = preferences.questionIndicatorColor
    }
}

private struct AgentIndicatorAppearanceKey: EnvironmentKey {
    static let defaultValue = AgentIndicatorAppearance()
}

public extension EnvironmentValues {
    var agentIndicatorAppearance: AgentIndicatorAppearance {
        get { self[AgentIndicatorAppearanceKey.self] }
        set { self[AgentIndicatorAppearanceKey.self] = newValue }
    }
}

public extension WorkspaceColor {
    var indicatorColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}
