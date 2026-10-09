import Foundation

public enum FinishedIndicatorIcon: String, Codable, CaseIterable, Sendable {
    case tickDraw
    case tick
    case tickRing
    case checkbox
    case servedDish
    case dot
    case flag
    case star
    case sparkle
    case inbox

    public var displayName: String {
        switch self {
        case .tickDraw: "Tick draws in"
        case .tick: "Filled tick"
        case .tickRing: "Soft tick"
        case .checkbox: "Checked box"
        case .servedDish: "Served dish"
        case .dot: "Done dot"
        case .flag: "Finish flag"
        case .star: "Star"
        case .sparkle: "Sparkle"
        case .inbox: "Inbox"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = Self(rawValue: value) ?? .tickDraw
    }
}

public enum QuestionIndicatorIcon: String, Codable, CaseIterable, Sendable {
    case pulsingBubble
    case wobble
    case ripple
    case cookAsks
    case typing
    case bounce
    case glow
    case thoughtCloud
    case raisedHand
    case backAndForth

    public var displayName: String {
        switch self {
        case .pulsingBubble: "Pulsing bubble"
        case .wobble: "Wobbling question mark"
        case .ripple: "Ripple"
        case .cookAsks: "Cook asks"
        case .typing: "Typing, then question mark"
        case .bounce: "Bouncing question mark"
        case .glow: "Glowing question mark"
        case .thoughtCloud: "Thought cloud"
        case .raisedHand: "Raised hand"
        case .backAndForth: "Back and forth"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = Self(rawValue: value) ?? .pulsingBubble
    }
}


public enum WorkingIndicatorIcon: String, Codable, CaseIterable, Sendable {
    case stirringCook
    case spinner
    case hoppingDots
    case breathingDot
    case progressSweep
    case turningGear
    case hourglass
    case levelBars
    case orbit
    case writingLines

    public var displayName: String {
        switch self {
        case .stirringCook: "Stirring cook"
        case .spinner: "Spinner"
        case .hoppingDots: "Hopping dots"
        case .breathingDot: "Breathing dot"
        case .progressSweep: "Progress sweep"
        case .turningGear: "Turning gear"
        case .hourglass: "Hourglass"
        case .levelBars: "Level bars"
        case .orbit: "Orbit"
        case .writingLines: "Writing lines"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = Self(rawValue: value) ?? .stirringCook
    }
}
