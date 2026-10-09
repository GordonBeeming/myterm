import SwiftUI

// Paths use the canvas’s 24-unit coordinate system so small and large glyphs share geometry.
internal enum AgentWorkingGlyphGeometry {
    static func draw(_ kind: String, context: GraphicsContext, color: Color, elapsed: Double, reduced: Bool) {
        switch kind {
        case "spinner":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 4.0, y: 4.0, width: 16.0, height: 16.0))
                layer.stroke(path, with: .color(color.opacity(0.22)), style: StrokeStyle(lineWidth: 2.4, lineCap: .butt, lineJoin: .miter))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "spin", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 12.0, y: 4.0))
                    p.addCurve(to: CGPoint(x: 20.0, y: 12.0), control1: CGPoint(x: 16.418278, y: 4.0), control2: CGPoint(x: 20.0, y: 7.581722))
                }
                layer.stroke(path, with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .miter))
            }
        case "hoppingDots":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "hop1", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 2.6, y: 10.6, width: 4.8, height: 4.8))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "hop2", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 9.6, y: 10.6, width: 4.8, height: 4.8))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "hop3", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 16.6, y: 10.6, width: 4.8, height: 4.8))
                layer.fill(path, with: .color(color.opacity(1)))
            }
        case "breathingDot":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "breathe", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 3.5, y: 3.5, width: 17.0, height: 17.0))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 7.8, y: 7.8, width: 8.4, height: 8.4))
                layer.fill(path, with: .color(color.opacity(1)))
            }
        case "progressSweep":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(roundedRect: CGRect(x: 2.5, y: 9.5, width: 19, height: 5), cornerRadius: 2.5)
                layer.fill(path, with: .color(color.opacity(0.22)))
            }
            do {
                var clipped = context
                clipped.clip(to: Path(roundedRect: CGRect(x: 2.5, y: 9.5, width: 19, height: 5), cornerRadius: 2.5))
                let layer = AgentGlyphMotion.context(clipped, motion: "sweep", elapsed: elapsed, reduced: reduced)
                let path = Path(roundedRect: CGRect(x: 2.5, y: 9.5, width: 8, height: 5), cornerRadius: 2.5)
                layer.fill(path, with: .color(color.opacity(1)))
            }
        case "turningGear":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "spin-slow", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 4.0, y: 4.0, width: 16.0, height: 16.0))
                layer.stroke(path, with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 3.4, lineCap: .butt, lineJoin: .miter, dash: [2.6, 3.68]))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "spin-slow", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 5.6, y: 5.6, width: 12.8, height: 12.8))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                var layer = AgentGlyphMotion.context(context, motion: "spin-slow", elapsed: elapsed, reduced: reduced)
                layer.blendMode = .destinationOut
                let path = Path(ellipseIn: CGRect(x: 9.6, y: 9.6, width: 4.8, height: 4.8))
                layer.fill(path, with: .color(Theme.surfaceRaised.opacity(1)))
            }
        case "hourglass":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "flip", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 6.5, y: 3.5))
                    p.addLine(to: CGPoint(x: 17.5, y: 3.5))
                    p.move(to: CGPoint(x: 6.5, y: 20.5))
                    p.addLine(to: CGPoint(x: 17.5, y: 20.5))
                }
                layer.stroke(path, with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .miter))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "flip", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 8.0, y: 3.5))
                    p.addCurve(to: CGPoint(x: 12.0, y: 12.0), control1: CGPoint(x: 8.0, y: 7.7), control2: CGPoint(x: 12.0, y: 9.1))
                    p.addCurve(to: CGPoint(x: 8.0, y: 20.5), control1: CGPoint(x: 12.0, y: 14.9), control2: CGPoint(x: 8.0, y: 16.3))
                    p.addLine(to: CGPoint(x: 16.0, y: 20.5))
                    p.addCurve(to: CGPoint(x: 12.0, y: 12.0), control1: CGPoint(x: 16.0, y: 16.3), control2: CGPoint(x: 12.0, y: 14.9))
                    p.addCurve(to: CGPoint(x: 16.0, y: 3.5), control1: CGPoint(x: 12.0, y: 9.1), control2: CGPoint(x: 16.0, y: 7.7))
                    p.addLine(to: CGPoint(x: 8.0, y: 3.5))
                    p.closeSubpath()
                }
                layer.stroke(path, with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 1.7, lineCap: .butt, lineJoin: .round))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "flip", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 9.4, y: 18.8))
                    p.addCurve(to: CGPoint(x: 12.0, y: 14.6), control1: CGPoint(x: 9.9, y: 16.9), control2: CGPoint(x: 12.0, y: 16.0))
                    p.addCurve(to: CGPoint(x: 14.6, y: 18.8), control1: CGPoint(x: 12.0, y: 16.0), control2: CGPoint(x: 14.1, y: 16.9))
                    p.addLine(to: CGPoint(x: 9.4, y: 18.8))
                    p.closeSubpath()
                }
                layer.fill(path, with: .color(color.opacity(1)))
            }
        case "levelBars":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "eq1", elapsed: elapsed, reduced: reduced)
                let path = Path(roundedRect: CGRect(x: 3.5, y: 5, width: 3.2, height: 14), cornerRadius: 1.6)
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "eq2", elapsed: elapsed, reduced: reduced)
                let path = Path(roundedRect: CGRect(x: 8.4, y: 5, width: 3.2, height: 14), cornerRadius: 1.6)
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "eq3", elapsed: elapsed, reduced: reduced)
                let path = Path(roundedRect: CGRect(x: 13.3, y: 5, width: 3.2, height: 14), cornerRadius: 1.6)
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "eq4", elapsed: elapsed, reduced: reduced)
                let path = Path(roundedRect: CGRect(x: 18.2, y: 5, width: 3.2, height: 14), cornerRadius: 1.6)
                layer.fill(path, with: .color(color.opacity(1)))
            }
        case "orbit":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 4.0, y: 4.0, width: 16.0, height: 16.0))
                layer.stroke(path, with: .color(color.opacity(0.25)), style: StrokeStyle(lineWidth: 1.4, lineCap: .butt, lineJoin: .miter))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 8.8, y: 8.8, width: 6.4, height: 6.4))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "spin", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 9.8, y: 1.8, width: 4.4, height: 4.4))
                layer.fill(path, with: .color(color.opacity(1)))
            }
        case "writingLines":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "write1", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 4.0, y: 6.5))
                    p.addLine(to: CGPoint(x: 20.0, y: 6.5))
                }
                layer.stroke(path, with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .miter, dash: [16], dashPhase: reduced ? 0 : AgentGlyphMotion.writingDashOffset("write1", elapsed: elapsed)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "write2", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 4.0, y: 12.0))
                    p.addLine(to: CGPoint(x: 20.0, y: 12.0))
                }
                layer.stroke(path, with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .miter, dash: [16], dashPhase: reduced ? 0 : AgentGlyphMotion.writingDashOffset("write2", elapsed: elapsed)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "write3", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 4.0, y: 17.5))
                    p.addLine(to: CGPoint(x: 14.0, y: 17.5))
                }
                layer.stroke(path, with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .miter, dash: [16], dashPhase: reduced ? 0 : AgentGlyphMotion.writingDashOffset("write3", elapsed: elapsed)))
            }
        default: break
        }
    }
}
