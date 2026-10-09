import SwiftUI

// Paths use the canvas’s 24-unit coordinate system so small and large glyphs share geometry.
internal enum AgentGlyphGeometry {
    static func draw(_ kind: String, context: GraphicsContext, color: Color, elapsed: Double, reduced: Bool) {
        switch kind {
        case "tickDraw":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 3.4, y: 3.4, width: 17.2, height: 17.2))
                layer.stroke(path, with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "draw", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 7.8, y: 12.4))
                    p.addLine(to: CGPoint(x: 10.7, y: 15.3))
                    p.addLine(to: CGPoint(x: 16.3, y: 9.3))
                }
                layer.stroke(path.trimmedPath(from: 0, to: reduced ? 1 : AgentGlyphMotion.tickTrim(elapsed: elapsed)), with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
        case "tick":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 3.0, y: 3.0, width: 18.0, height: 18.0))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 7.6, y: 12.4))
                    p.addLine(to: CGPoint(x: 10.6, y: 15.4))
                    p.addLine(to: CGPoint(x: 16.4, y: 9.2))
                }
                layer.stroke(path, with: .color(.white.opacity(1)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
        case "tickRing":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 3.4, y: 3.4, width: 17.2, height: 17.2))
                layer.fill(path, with: .color(color.opacity(0.18)))
                layer.stroke(path, with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 7.8, y: 12.4))
                    p.addLine(to: CGPoint(x: 10.7, y: 15.3))
                    p.addLine(to: CGPoint(x: 16.3, y: 9.3))
                }
                layer.stroke(path, with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
        case "checkbox":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(roundedRect: CGRect(x: 3.5, y: 3.5, width: 17, height: 17), cornerRadius: 4.5)
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 8.0, y: 12.3))
                    p.addLine(to: CGPoint(x: 10.8, y: 15.1))
                    p.addLine(to: CGPoint(x: 16.2, y: 9.3))
                }
                layer.stroke(path, with: .color(.white.opacity(1)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
        case "servedDish":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 10.4, y: 4.8, width: 3.2, height: 3.2))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 4.6, y: 16.2))
                    p.addCurve(to: CGPoint(x: 12.0, y: 8.8), control1: CGPoint(x: 4.6, y: 12.113093), control2: CGPoint(x: 7.913093, y: 8.8))
                    p.addCurve(to: CGPoint(x: 19.4, y: 16.2), control1: CGPoint(x: 16.086907, y: 8.8), control2: CGPoint(x: 19.4, y: 12.113093))
                    p.addLine(to: CGPoint(x: 4.6, y: 16.2))
                    p.closeSubpath()
                }
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 3.0, y: 18.6))
                    p.addLine(to: CGPoint(x: 21.0, y: 18.6))
                }
                layer.stroke(path, with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 8.4, y: 12.2))
                    p.addCurve(to: CGPoint(x: 10.8, y: 9.9), control1: CGPoint(x: 8.828473, y: 11.121479), control2: CGPoint(x: 9.70423, y: 10.282212))
                }
                layer.stroke(path, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            }
        case "dot":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 5.0, y: 5.0, width: 14.0, height: 14.0))
                layer.fill(path, with: .color(color.opacity(0.24)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 8.0, y: 8.0, width: 8.0, height: 8.0))
                layer.fill(path, with: .color(color.opacity(1)))
            }
        case "flag":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 6.5, y: 3.5))
                    p.addLine(to: CGPoint(x: 6.5, y: 20.5))
                }
                layer.stroke(path, with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 6.5, y: 4.5))
                    p.addLine(to: CGPoint(x: 17.5, y: 4.5))
                    p.addLine(to: CGPoint(x: 14.9, y: 8.1))
                    p.addLine(to: CGPoint(x: 17.5, y: 11.7))
                    p.addLine(to: CGPoint(x: 6.5, y: 11.7))
                    p.addLine(to: CGPoint(x: 6.5, y: 4.5))
                    p.closeSubpath()
                }
                layer.fill(path, with: .color(color.opacity(1)))
            }
        case "star":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 12.0, y: 3.2))
                    p.addLine(to: CGPoint(x: 14.6, y: 8.7))
                    p.addLine(to: CGPoint(x: 20.6, y: 9.4))
                    p.addLine(to: CGPoint(x: 16.2, y: 13.5))
                    p.addLine(to: CGPoint(x: 17.4, y: 19.4))
                    p.addLine(to: CGPoint(x: 12.0, y: 16.5))
                    p.addLine(to: CGPoint(x: 6.6, y: 19.4))
                    p.addLine(to: CGPoint(x: 7.8, y: 13.5))
                    p.addLine(to: CGPoint(x: 3.4, y: 9.4))
                    p.addLine(to: CGPoint(x: 9.4, y: 8.7))
                    p.addLine(to: CGPoint(x: 12.0, y: 3.2))
                    p.closeSubpath()
                }
                layer.fill(path, with: .color(color.opacity(1)))
                layer.stroke(path, with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
            }
        case "sparkle":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 11.0, y: 3.0))
                    p.addCurve(to: CGPoint(x: 18.0, y: 10.0), control1: CGPoint(x: 11.8, y: 7.6), control2: CGPoint(x: 13.4, y: 9.2))
                    p.addCurve(to: CGPoint(x: 11.0, y: 17.0), control1: CGPoint(x: 13.4, y: 10.8), control2: CGPoint(x: 11.8, y: 12.4))
                    p.addCurve(to: CGPoint(x: 4.0, y: 10.0), control1: CGPoint(x: 10.2, y: 12.4), control2: CGPoint(x: 8.6, y: 10.8))
                    p.addCurve(to: CGPoint(x: 11.0, y: 3.0), control1: CGPoint(x: 8.6, y: 9.2), control2: CGPoint(x: 10.2, y: 7.6))
                    p.closeSubpath()
                }
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 18.5, y: 14.5))
                    p.addCurve(to: CGPoint(x: 21.4, y: 17.4), control1: CGPoint(x: 18.85, y: 16.4), control2: CGPoint(x: 19.5, y: 17.1))
                    p.addCurve(to: CGPoint(x: 18.5, y: 20.3), control1: CGPoint(x: 19.5, y: 17.75), control2: CGPoint(x: 18.85, y: 18.4))
                    p.addCurve(to: CGPoint(x: 15.6, y: 17.4), control1: CGPoint(x: 18.15, y: 18.4), control2: CGPoint(x: 17.5, y: 17.75))
                    p.addCurve(to: CGPoint(x: 18.5, y: 14.5), control1: CGPoint(x: 17.5, y: 17.1), control2: CGPoint(x: 18.15, y: 16.4))
                    p.closeSubpath()
                }
                layer.fill(path, with: .color(color.opacity(1)))
            }
        case "inbox":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 3.5, y: 13.5))
                    p.addLine(to: CGPoint(x: 6.0, y: 6.0))
                    p.addLine(to: CGPoint(x: 18.0, y: 6.0))
                    p.addLine(to: CGPoint(x: 20.5, y: 13.5))
                    p.addLine(to: CGPoint(x: 20.5, y: 17.5))
                    p.addCurve(to: CGPoint(x: 19.0, y: 19.0), control1: CGPoint(x: 20.5, y: 18.328427), control2: CGPoint(x: 19.828427, y: 19.0))
                    p.addLine(to: CGPoint(x: 5.0, y: 19.0))
                    p.addCurve(to: CGPoint(x: 3.5, y: 17.5), control1: CGPoint(x: 4.171573, y: 19.0), control2: CGPoint(x: 3.5, y: 18.328427))
                    p.addLine(to: CGPoint(x: 3.5, y: 13.5))
                    p.closeSubpath()
                }
                layer.fill(path, with: .color(color.opacity(0.18)))
                layer.stroke(path, with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 3.5, y: 13.5))
                    p.addLine(to: CGPoint(x: 8.5, y: 13.5))
                    p.addLine(to: CGPoint(x: 9.7, y: 15.5))
                    p.addLine(to: CGPoint(x: 14.3, y: 15.5))
                    p.addLine(to: CGPoint(x: 15.5, y: 13.5))
                    p.addLine(to: CGPoint(x: 20.5, y: 13.5))
                }
                layer.stroke(path, with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
        case "pulsingBubble":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "pulse", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 5.0, y: 4.5))
                    p.addLine(to: CGPoint(x: 19.0, y: 4.5))
                    p.addCurve(to: CGPoint(x: 21.0, y: 6.5), control1: CGPoint(x: 20.104569, y: 4.5), control2: CGPoint(x: 21.0, y: 5.395431))
                    p.addLine(to: CGPoint(x: 21.0, y: 15.0))
                    p.addCurve(to: CGPoint(x: 19.0, y: 17.0), control1: CGPoint(x: 21.0, y: 16.104569), control2: CGPoint(x: 20.104569, y: 17.0))
                    p.addLine(to: CGPoint(x: 11.8, y: 17.0))
                    p.addLine(to: CGPoint(x: 7.5, y: 20.4))
                    p.addLine(to: CGPoint(x: 7.5, y: 17.0))
                    p.addLine(to: CGPoint(x: 5.0, y: 17.0))
                    p.addCurve(to: CGPoint(x: 3.0, y: 15.0), control1: CGPoint(x: 3.895431, y: 17.0), control2: CGPoint(x: 3.0, y: 16.104569))
                    p.addLine(to: CGPoint(x: 3.0, y: 6.5))
                    p.addCurve(to: CGPoint(x: 5.0, y: 4.5), control1: CGPoint(x: 3.0, y: 5.395431), control2: CGPoint(x: 3.895431, y: 4.5))
                    p.closeSubpath()
                }
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "pulse", elapsed: elapsed, reduced: reduced)
                layer.draw(Text("?").font(.system(size: 10.5, weight: .heavy, design: .rounded)).foregroundColor(.white), at: CGPoint(x: 12.0, y: 10.925))
            }
        case "wobble":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "tilt", elapsed: elapsed, reduced: reduced)
                layer.draw(Text("?").font(.system(size: 23.0, weight: .heavy, design: .rounded)).foregroundColor(color), at: CGPoint(x: 12.0, y: 12.45))
            }
        case "ripple":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "ripple", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 4.0, y: 4.0, width: 16.0, height: 16.0))
                layer.stroke(path, with: .color(color.opacity(1)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 4.0, y: 4.0, width: 16.0, height: 16.0))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                layer.draw(Text("?").font(.system(size: 11.5, weight: .heavy, design: .rounded)).foregroundColor(.white), at: CGPoint(x: 12.0, y: 12.175))
            }
        case "cookAsks":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 5.4, y: 6.8, width: 7.2, height: 7.2))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(roundedRect: CGRect(x: 3.8, y: 13.8, width: 10.4, height: 4.6), cornerRadius: 2.2)
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                var layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                layer.blendMode = .destinationOut
                let path = Path(ellipseIn: CGRect(x: 3.3, y: 2.3, width: 4.6, height: 4.6))
                layer.stroke(path, with: .color(Theme.surfaceRaised.opacity(1)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            do {
                var layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                layer.blendMode = .destinationOut
                let path = Path(ellipseIn: CGRect(x: 6.3, y: 1.5, width: 5.4, height: 5.4))
                layer.stroke(path, with: .color(Theme.surfaceRaised.opacity(1)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            do {
                var layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                layer.blendMode = .destinationOut
                let path = Path(ellipseIn: CGRect(x: 10.1, y: 2.3, width: 4.6, height: 4.6))
                layer.stroke(path, with: .color(Theme.surfaceRaised.opacity(1)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            do {
                var layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                layer.blendMode = .destinationOut
                let path = Path(roundedRect: CGRect(x: 4.9, y: 4.9, width: 8.2, height: 2.6), cornerRadius: 0.9)
                layer.stroke(path, with: .color(Theme.surfaceRaised.opacity(1)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 3.3, y: 2.3, width: 4.6, height: 4.6))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 6.3, y: 1.5, width: 5.4, height: 5.4))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 10.1, y: 2.3, width: 4.6, height: 4.6))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(roundedRect: CGRect(x: 4.9, y: 4.9, width: 8.2, height: 2.6), cornerRadius: 0.9)
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                var layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                layer.blendMode = .destinationOut
                let path = Path(roundedRect: CGRect(x: 2, y: 15.2, width: 15, height: 2.4), cornerRadius: 1)
                layer.stroke(path, with: .color(Theme.surfaceRaised.opacity(1)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            do {
                var layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                layer.blendMode = .destinationOut
                let path = Path(roundedRect: CGRect(x: 3.6, y: 16.9, width: 11.8, height: 6.2), cornerRadius: 1.9)
                layer.stroke(path, with: .color(Theme.surfaceRaised.opacity(1)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(roundedRect: CGRect(x: 2, y: 15.2, width: 15, height: 2.4), cornerRadius: 1)
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(roundedRect: CGRect(x: 3.6, y: 16.9, width: 11.8, height: 6.2), cornerRadius: 1.9)
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                var layer = AgentGlyphMotion.context(context, motion: "bob", elapsed: elapsed, reduced: reduced)
                layer.blendMode = .destinationOut
                let path = Path(ellipseIn: CGRect(x: 13.8, y: 0.8, width: 10.4, height: 10.4))
                layer.fill(path, with: .color(Theme.surfaceRaised.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "bob", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 14.6, y: 1.6, width: 8.8, height: 8.8))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "bob", elapsed: elapsed, reduced: reduced)
                layer.draw(Text("?").font(.system(size: 7.6, weight: .heavy, design: .rounded)).foregroundColor(.white), at: CGPoint(x: 19.0, y: 6.44))
            }
        case "typing":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 5.0, y: 4.5))
                    p.addLine(to: CGPoint(x: 19.0, y: 4.5))
                    p.addCurve(to: CGPoint(x: 21.0, y: 6.5), control1: CGPoint(x: 20.104569, y: 4.5), control2: CGPoint(x: 21.0, y: 5.395431))
                    p.addLine(to: CGPoint(x: 21.0, y: 15.0))
                    p.addCurve(to: CGPoint(x: 19.0, y: 17.0), control1: CGPoint(x: 21.0, y: 16.104569), control2: CGPoint(x: 20.104569, y: 17.0))
                    p.addLine(to: CGPoint(x: 11.8, y: 17.0))
                    p.addLine(to: CGPoint(x: 7.5, y: 20.4))
                    p.addLine(to: CGPoint(x: 7.5, y: 17.0))
                    p.addLine(to: CGPoint(x: 5.0, y: 17.0))
                    p.addCurve(to: CGPoint(x: 3.0, y: 15.0), control1: CGPoint(x: 3.895431, y: 17.0), control2: CGPoint(x: 3.0, y: 16.104569))
                    p.addLine(to: CGPoint(x: 3.0, y: 6.5))
                    p.addCurve(to: CGPoint(x: 5.0, y: 4.5), control1: CGPoint(x: 3.0, y: 5.395431), control2: CGPoint(x: 3.895431, y: 4.5))
                    p.closeSubpath()
                }
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "dots", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 6.6, y: 9.4, width: 2.8, height: 2.8))
                layer.fill(path, with: .color(.white.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "dots", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 10.6, y: 9.4, width: 2.8, height: 2.8))
                layer.fill(path, with: .color(.white.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "dots", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 14.6, y: 9.4, width: 2.8, height: 2.8))
                layer.fill(path, with: .color(.white.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "qappear", elapsed: elapsed, reduced: reduced)
                layer.draw(Text("?").font(.system(size: 10.5, weight: .heavy, design: .rounded)).foregroundColor(.white), at: CGPoint(x: 12.0, y: 10.925))
            }
        case "bounce":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "bounce", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 3.6, y: 3.6, width: 16.8, height: 16.8))
                layer.fill(path, with: .color(color.opacity(0.2)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "bounce", elapsed: elapsed, reduced: reduced)
                layer.draw(Text("?").font(.system(size: 15.0, weight: .heavy, design: .rounded)).foregroundColor(color), at: CGPoint(x: 12.0, y: 12.35))
            }
        case "glow":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "glow", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 1.5, y: 1.5, width: 21.0, height: 21.0))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 4.4, y: 4.4, width: 15.2, height: 15.2))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                layer.draw(Text("?").font(.system(size: 11.0, weight: .heavy, design: .rounded)).foregroundColor(.white), at: CGPoint(x: 12.0, y: 12.15))
            }
        case "thoughtCloud":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "bob", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 6.0, y: 2.0, width: 15.0, height: 15.0))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "bob", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 3.3, y: 15.7, width: 3.8, height: 3.8))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "bob", elapsed: elapsed, reduced: reduced)
                let path = Path(ellipseIn: CGRect(x: 1.5, y: 20.1, width: 2.2, height: 2.2))
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "bob", elapsed: elapsed, reduced: reduced)
                layer.draw(Text("?").font(.system(size: 11.0, weight: .heavy, design: .rounded)).foregroundColor(.white), at: CGPoint(x: 13.5, y: 9.75))
            }
        case "raisedHand":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "wave", elapsed: elapsed, reduced: reduced)
                let path = Path(roundedRect: CGRect(x: 7, y: 11, width: 10.4, height: 10.6), cornerRadius: 3.8)
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "wave", elapsed: elapsed, reduced: reduced)
                let path = Path(roundedRect: CGRect(x: 7, y: 4.6, width: 2.3, height: 9), cornerRadius: 1.15)
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "wave", elapsed: elapsed, reduced: reduced)
                let path = Path(roundedRect: CGRect(x: 9.7, y: 3.2, width: 2.3, height: 10), cornerRadius: 1.15)
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "wave", elapsed: elapsed, reduced: reduced)
                let path = Path(roundedRect: CGRect(x: 12.4, y: 3.8, width: 2.3, height: 9.5), cornerRadius: 1.15)
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "wave", elapsed: elapsed, reduced: reduced)
                let path = Path(roundedRect: CGRect(x: 15.1, y: 5.6, width: 2.3, height: 8), cornerRadius: 1.15)
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                var layer = AgentGlyphMotion.context(context, motion: "wave", elapsed: elapsed, reduced: reduced)
                layer.translateBy(x: 5.15, y: 14.1)
                layer.rotate(by: .degrees(-32.0))
                layer.translateBy(x: -5.15, y: -14.1)
                let path = Path(roundedRect: CGRect(x: 4, y: 10.6, width: 2.3, height: 7), cornerRadius: 1.15)
                layer.fill(path, with: .color(color.opacity(1)))
            }
        case "backAndForth":
            do {
                let layer = AgentGlyphMotion.context(context, motion: "", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 3.5, y: 3.0))
                    p.addLine(to: CGPoint(x: 12.5, y: 3.0))
                    p.addCurve(to: CGPoint(x: 14.1, y: 4.6), control1: CGPoint(x: 13.383656, y: 3.0), control2: CGPoint(x: 14.1, y: 3.716344))
                    p.addLine(to: CGPoint(x: 14.1, y: 9.6))
                    p.addCurve(to: CGPoint(x: 12.5, y: 11.2), control1: CGPoint(x: 14.1, y: 10.483656), control2: CGPoint(x: 13.383656, y: 11.2))
                    p.addLine(to: CGPoint(x: 7.6, y: 11.2))
                    p.addLine(to: CGPoint(x: 5.0, y: 13.4))
                    p.addLine(to: CGPoint(x: 5.0, y: 11.2))
                    p.addLine(to: CGPoint(x: 3.5, y: 11.2))
                    p.addCurve(to: CGPoint(x: 1.9, y: 9.6), control1: CGPoint(x: 2.616344, y: 11.2), control2: CGPoint(x: 1.9, y: 10.483656))
                    p.addLine(to: CGPoint(x: 1.9, y: 4.6))
                    p.addCurve(to: CGPoint(x: 3.5, y: 3.0), control1: CGPoint(x: 1.9, y: 3.716344), control2: CGPoint(x: 2.616344, y: 3.0))
                    p.closeSubpath()
                }
                layer.fill(path, with: .color(color.opacity(0.4)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "pulse2", elapsed: elapsed, reduced: reduced)
                let path = Path { p in
                    p.move(to: CGPoint(x: 10.5, y: 9.5))
                    p.addLine(to: CGPoint(x: 20.5, y: 9.5))
                    p.addCurve(to: CGPoint(x: 22.3, y: 11.3), control1: CGPoint(x: 21.494113, y: 9.5), control2: CGPoint(x: 22.3, y: 10.305887))
                    p.addLine(to: CGPoint(x: 22.3, y: 17.3))
                    p.addCurve(to: CGPoint(x: 20.5, y: 19.1), control1: CGPoint(x: 22.3, y: 18.294113), control2: CGPoint(x: 21.494113, y: 19.1))
                    p.addLine(to: CGPoint(x: 18.9, y: 19.1))
                    p.addLine(to: CGPoint(x: 18.9, y: 21.7))
                    p.addLine(to: CGPoint(x: 15.9, y: 19.1))
                    p.addLine(to: CGPoint(x: 10.5, y: 19.1))
                    p.addCurve(to: CGPoint(x: 8.7, y: 17.3), control1: CGPoint(x: 9.505887, y: 19.1), control2: CGPoint(x: 8.7, y: 18.294113))
                    p.addLine(to: CGPoint(x: 8.7, y: 11.3))
                    p.addCurve(to: CGPoint(x: 10.5, y: 9.5), control1: CGPoint(x: 8.7, y: 10.305887), control2: CGPoint(x: 9.505887, y: 9.5))
                    p.closeSubpath()
                }
                layer.fill(path, with: .color(color.opacity(1)))
            }
            do {
                let layer = AgentGlyphMotion.context(context, motion: "pulse2", elapsed: elapsed, reduced: reduced)
                layer.draw(Text("?").font(.system(size: 8.6, weight: .heavy, design: .rounded)).foregroundColor(.white), at: CGPoint(x: 15.5, y: 14.59))
            }
        default: break
        }
    }
}
