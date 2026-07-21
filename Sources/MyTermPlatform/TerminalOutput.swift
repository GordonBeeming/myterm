import Foundation

public enum TerminalOutputSnapshot {
    public static func plainText(from text: String, maximumCharacters: Int) -> String {
        guard maximumCharacters > 0 else { return "" }

        var result = String.UnicodeScalarView()
        result.reserveCapacity(text.unicodeScalars.count)
        var escapeState = EscapeState.none
        for scalar in text.unicodeScalars {
            switch escapeState {
            case .escape:
                switch scalar.value {
                case 0x5B:
                    escapeState = .controlSequence
                case 0x5D:
                    escapeState = .operatingSystemCommand
                default:
                    escapeState = .none
                }
                continue
            case .controlSequence:
                if (0x40...0x7E).contains(scalar.value) {
                    escapeState = .none
                }
                continue
            case .operatingSystemCommand:
                if scalar.value == 0x07 {
                    escapeState = .none
                } else if scalar.value == 0x1B {
                    escapeState = .escape
                }
                continue
            case .none:
                break
            }
            switch scalar.value {
            case 0x1B:
                escapeState = .escape
            case 0x09, 0x0A:
                result.append(scalar)
            case 0x0D:
                result.append("\n")
            case 0x00...0x1F, 0x7F...0x9F:
                continue
            default:
                result.append(scalar)
            }
        }
        return String(String(result).suffix(maximumCharacters))
    }

    private enum EscapeState {
        case none
        case escape
        case controlSequence
        case operatingSystemCommand
    }
}

@MainActor
public final class TerminalContentChangeCoalescer {
    private let delay: TimeInterval
    private var pendingNotification: DispatchWorkItem?

    public init(delay: TimeInterval = 0.15) {
        self.delay = max(delay, 0)
    }

    public func notify(_ handler: @escaping @MainActor () -> Void) {
        guard pendingNotification == nil else { return }

        let notification = DispatchWorkItem { [weak self] in
            self?.pendingNotification = nil
            handler()
        }
        pendingNotification = notification
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: notification)
    }

    public func cancel() {
        pendingNotification?.cancel()
        pendingNotification = nil
    }
}
