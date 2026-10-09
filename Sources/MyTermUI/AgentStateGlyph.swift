import MyTermCore
import SwiftUI

public struct AgentStateGlyph: View {
    private let kind: String
    private let isLooping: Bool
    private let color: Color
    private let side: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var appearedAt = Date()
    @State private var hasDrawnTick = false

    public init(working: WorkingIndicatorIcon, color: Color, side: CGFloat = 15) {
        kind = working.rawValue
        isLooping = true
        self.color = color
        self.side = side
    }

    public init(finished: FinishedIndicatorIcon, color: Color, side: CGFloat = 15) {
        kind = finished.rawValue
        isLooping = false
        self.color = color
        self.side = side
    }

    public init(question: QuestionIndicatorIcon, color: Color, side: CGFloat = 15) {
        kind = question.rawValue
        isLooping = true
        self.color = color
        self.side = side
    }

    public var body: some View {
        Group {
            if kind == WorkingIndicatorIcon.stirringCook.rawValue {
                AgentChefIcon(color: color, isStirring: !reducedMotion)
                    .frame(width: side, height: side)
            } else {
                timelineGlyph
            }
        }
        .accessibilityHidden(true)
    }

    private var timelineGlyph: some View {
        TimelineView(.animation(paused: reducedMotion || (!isLooping && (kind != "tickDraw" || hasDrawnTick)))) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(appearedAt))
            Canvas { context, size in
                var scaled = context
                // The SVG permits overflow; a larger drawing surface keeps the fading ring round.
                scaled.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
                scaled.scaleBy(x: side / 24, y: side / 24)
                AgentGlyphGeometry.draw(kind, context: scaled, color: color, elapsed: elapsed, reduced: reducedMotion)
                AgentWorkingGlyphGeometry.draw(kind, context: scaled, color: color, elapsed: elapsed, reduced: reducedMotion)
            }
            .frame(width: side * 4 / 3, height: side * 4 / 3)
            .onChange(of: elapsed >= 0.9, initial: true) { _, completed in
                if completed { hasDrawnTick = true }
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
        .onAppear {
            appearedAt = Date()
            hasDrawnTick = false
        }
        .onChange(of: kind) { _, _ in
            appearedAt = Date()
            hasDrawnTick = false
        }
    }
}

internal enum AgentGlyphMotion {
    // CSS easing describes x as time, so invert its Bezier x before sampling y.
    static func easing(_ progress: Double, easeOut: Bool = false) -> Double {
        let x1 = easeOut ? 0.0 : 0.42
        let x2 = 0.58
        let progress = min(max(progress, 0), 1)
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<24 {
            let t = (lower + upper) / 2
            let x = 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t
            if x < progress { lower = t } else { upper = t }
        }
        let t = (lower + upper) / 2
        return 3 * (1 - t) * t * t + t * t * t
    }

    static func tickTrim(elapsed: Double) -> Double {
        // The canvas dash is longer than its tick path, so the visible stroke completes before the dash does.
        let pathLength = hypot(2.9, 2.9) + hypot(5.6, 6)
        return min(1, easing(elapsed / 0.9, easeOut: true) * 14 / pathLength)
    }

    // Interpolation keeps the canvas keyframe holds while easing between its poses.
    static func value(_ elapsed: Double, duration: Double, frames: [(Double, Double)], easeOut: Bool = false) -> Double {
        let phase = elapsed.truncatingRemainder(dividingBy: duration) / duration
        for index in 1..<frames.count where phase <= frames[index].0 {
            let start = frames[index - 1]
            let end = frames[index]
            let progress = (phase - start.0) / (end.0 - start.0)
            let eased = easing(progress, easeOut: easeOut)
            return start.1 + (end.1 - start.1) * eased
        }
        return frames.last?.1 ?? 0
    }

    static func writingDashOffset(_ motion: String, elapsed: Double) -> Double {
        let phase = elapsed.truncatingRemainder(dividingBy: 2.4) / 2.4
        let progress: Double
        switch motion {
        case "write1": progress = min(phase / 0.2, 1)
        case "write2": progress = min(max((phase - 0.2) / 0.2, 0), 1)
        case "write3":
            progress = phase > 0.9 ? (1 - phase) / 0.1 : min(max((phase - 0.4) / 0.2, 0), 1)
        default: progress = 1
        }
        return 16 * (1 - progress)
    }

    static func context(_ original: GraphicsContext, motion: String, elapsed: Double, reduced: Bool) -> GraphicsContext {
        var context = original
        var scale = 1.0
        var angle = 0.0
        var y = 0.0
        var x = 0.0
        var scaleY = 1.0
        var origin = CGPoint(x: 12, y: 12)
        if reduced {
            if motion == "dots" { context.opacity = 0 }
            if motion == "glow" { context.opacity = 0.25 }
        } else {
            switch motion {
            case "spin", "spin-slow":
                let duration = motion == "spin" ? 0.9 : 2.6
                angle = elapsed.truncatingRemainder(dividingBy: duration) / duration * 360
            case "hop1", "hop2", "hop3":
                let delay = motion == "hop2" ? 0.15 : motion == "hop3" ? 0.3 : 0
                y = value(max(0, elapsed - delay), duration: 1.2, frames: [(0, 0), (0.3, -3.5), (0.6, 0), (1, 0)])
            case "breathe":
                scale = value(elapsed, duration: 2.2, frames: [(0, 0.7), (0.5, 1), (1, 0.7)])
                context.opacity = value(elapsed, duration: 2.2, frames: [(0, 0.15), (0.5, 0.4), (1, 0.15)])
            case "sweep":
                x = value(elapsed, duration: 1.4, frames: [(0, -8), (1, 19)])
            case "flip":
                angle = value(elapsed, duration: 2.4, frames: [(0, 0), (0.7, 0), (0.85, 180), (1, 180)])
            case "eq1", "eq2", "eq3", "eq4":
                origin.y = 19
                let advance = motion == "eq2" ? 0.4 : motion == "eq3" ? 0.7 : motion == "eq4" ? 0.2 : 0
                scaleY = value(elapsed + advance, duration: 1, frames: [(0, 0.35), (0.5, 1), (1, 0.35)])
            case "pulse", "pulse2":
                scale = value(elapsed, duration: 1.6, frames: [(0, 1), (0.3, 1.14), (0.6, 1), (1, 1)])
                if motion == "pulse2" { origin = CGPoint(x: 15.5, y: 15) }
            case "tilt":
                origin.y = 19
                angle = value(elapsed, duration: 2.4, frames: [(0, 0), (0.08, -16), (0.16, 14), (0.24, -8), (0.32, 0), (1, 0)])
            case "ripple":
                let phase = elapsed.truncatingRemainder(dividingBy: 1.8) / 1.8
                let eased = easing(phase, easeOut: true)
                scale = 1 + 0.6 * eased
                context.opacity = 0.8 * (1 - eased)
            case "bob":
                y = value(elapsed, duration: 1.4, frames: [(0, 0), (0.5, -1.6), (1, 0)])
            case "bounce":
                y = value(elapsed, duration: 2, frames: [(0, 0), (0.12, -3.2), (0.24, 0), (0.32, -1.2), (0.4, 0), (1, 0)], easeOut: true)
            case "glow":
                scale = value(elapsed, duration: 1.8, frames: [(0, 0.9), (0.5, 1.08), (1, 0.9)])
                context.opacity = value(elapsed, duration: 1.8, frames: [(0, 0.12), (0.5, 0.45), (1, 0.12)])
            case "wave":
                origin.y = 21
                angle = value(elapsed, duration: 2.2, frames: [(0, 0), (0.1, -14), (0.2, 12), (0.3, -10), (0.4, 6), (0.5, 0), (1, 0)])
            case "dots", "qappear":
                let showsDots = elapsed.truncatingRemainder(dividingBy: 2.4) / 2.4 < 0.55
                context.opacity = (motion == "dots" ? showsDots : !showsDots) ? 1 : 0
            default: break
            }
        }
        context.translateBy(x: origin.x + x, y: origin.y + y)
        context.scaleBy(x: scale, y: scale * scaleY)
        context.rotate(by: .degrees(angle))
        context.translateBy(x: -origin.x, y: -origin.y)
        return context
    }
}
