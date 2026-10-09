import MyTermCore
import SwiftUI

public struct AgentIdentityIcon: View {
    private let identity: AgentIdentity

    public init(identity: AgentIdentity) {
        self.identity = identity
    }

    public var body: some View {
        IdentityShape(identity: identity)
            .fill(identity == .claude
                ? Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
                : Theme.adaptiveColor(dark: 0xE6E8EB, light: 0x3A3F47))
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel(identity.displayName)
    }
}

private struct IdentityShape: Shape {
    let identity: AgentIdentity

    func path(in rect: CGRect) -> Path {
        var outline = Path()
        switch identity {
        case .claude:
            for angle in [Double.pi / 2, Double.pi / 6, -Double.pi / 6] {
                let dx = 5.4 * cos(angle)
                let dy = 5.4 * sin(angle)
                outline.move(to: CGPoint(x: 8 - dx, y: 8 - dy))
                outline.addLine(to: CGPoint(x: 8 + dx, y: 8 + dy))
            }
            outline = outline.strokedPath(StrokeStyle(lineWidth: 1.5, lineCap: .round))
        case .codex:
            for vertex in 0..<6 {
                let angle = Double(vertex) * .pi / 3 - .pi / 2
                let point = CGPoint(x: 8 + 5.4 * cos(angle), y: 8 + 5.4 * sin(angle))
                if vertex == 0 { outline.move(to: point) } else { outline.addLine(to: point) }
            }
            outline.closeSubpath()
            outline = outline.strokedPath(StrokeStyle(lineWidth: 1.4))
            outline.addEllipse(in: CGRect(x: 6.7, y: 6.7, width: 2.6, height: 2.6))
        }
        let scale = min(rect.width, rect.height) / 16
        return outline.applying(CGAffineTransform(
            translationX: rect.midX - 8 * scale, y: rect.midY - 8 * scale
        ).scaledBy(x: scale, y: scale))
    }
}
