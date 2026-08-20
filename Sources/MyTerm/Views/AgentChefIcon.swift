import SwiftUI

/// A cook stirring a pot, drawn small enough to sit inside a tab.
///
/// The figure is laid out in a 24-point square and each shape maps that square onto the frame it is
/// given, so the same drawing serves the tab strip and the sidebar without a second asset.
/// Everything is one colour: the state is carried by that colour, and by whether the spoon moves.
struct AgentChefIcon: View {
    let color: Color
    let isStirring: Bool

    /// How far the spoon swings either side of its resting lean, and how long each pose is held.
    private static let stirSwing: Double = 14
    private static let frameDuration: Double = 0.45

    var body: some View {
        Group {
            if isStirring {
                TimelineView(.periodic(from: .now, by: Self.frameDuration)) { context in
                    drawing(spoonAngle: Self.spoonAngle(at: context.date))
                }
            } else {
                drawing(spoonAngle: 0)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Two poses, swapped on a timer, rather than a sweep between them.
    ///
    /// At the size this is drawn, a smooth rotation of a few points reads as a blur, and at a
    /// glance as nothing at all. A hard cut between two positions reads as movement. Every cook on
    /// screen takes its pose from the clock, so they all stir together.
    static func spoonAngle(at date: Date) -> Double {
        let frame = Int(date.timeIntervalSinceReferenceDate / frameDuration)
        return frame.isMultiple(of: 2) ? -stirSwing : stirSwing
    }

    /// The figure faces us, hat and head centred over a pot the full width of the square: at tab
    /// size only a handful of masses survive, so each one is as big as the square allows.
    ///
    /// The haloes are the reason this composites as one group: each one cuts a gap out of whatever
    /// was drawn before it, so the hat reads as sitting on the face, the spoon as a separate
    /// object, and the pot as standing in front of the cook. Without them a single-colour drawing
    /// this small merges into one blob.
    private func drawing(spoonAngle: Double) -> some View {
        ZStack {
            ChefCook().fill(color)

            ChefHat(isHalo: true).fill(style: FillStyle(eoFill: true)).blendMode(.destinationOut)
            ChefHat().fill(color)

            ChefSpoon(isHalo: true).fill(style: FillStyle(eoFill: true)).blendMode(.destinationOut)
                .rotationEffect(.degrees(spoonAngle), anchor: ChefDrawing.spoonPivotAnchor)
            ChefSpoon().fill(color)
                .rotationEffect(.degrees(spoonAngle), anchor: ChefDrawing.spoonPivotAnchor)

            ChefPot(isHalo: true).fill(style: FillStyle(eoFill: true)).blendMode(.destinationOut)
            ChefPot().fill(color)
        }
        .compositingGroup()
    }
}

private enum ChefDrawing {
    static let side: CGFloat = 24
    /// Half of this sits outside the shape it traces, which is the width of the gap it opens up.
    static let haloWidth: CGFloat = 1.8
    /// Where the spoon meets the stew: turning it here keeps the lower end planted in the pot
    /// while the handle end does the travelling, which is what stirring looks like.
    static let spoonPivot = CGPoint(x: 16.8, y: 16.2)
    static var spoonPivotAnchor: UnitPoint {
        UnitPoint(x: spoonPivot.x / side, y: spoonPivot.y / side)
    }

    /// Maps the 24-point square onto the frame the shape was given, keeping the drawing centred
    /// and square. Stroke widths are traced before this runs, so they scale with everything else.
    static func transform(in rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width, rect.height) / side
        let drawn = side * scale
        return CGAffineTransform(
            translationX: rect.minX + (rect.width - drawn) / 2,
            y: rect.minY + (rect.height - drawn) / 2
        )
        .scaledBy(x: scale, y: scale)
    }

    static func limb(from start: CGPoint, to end: CGPoint, width: CGFloat) -> Path {
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        return line.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
    }

    static func finish(_ path: Path, isHalo: Bool, in rect: CGRect) -> Path {
        let shape = isHalo ? path.strokedPath(StrokeStyle(lineWidth: haloWidth)) : path
        return shape.applying(transform(in: rect))
    }
}

/// The face and shoulders. The shoulders mostly hide behind the pot; what they add is width, so
/// the head does not sit on the rim like a ball balanced on a shelf.
private struct ChefCook: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: 6.2, y: 5.8, width: 7.6, height: 7.6))
        path.addRoundedRect(in: CGRect(x: 4.6, y: 13.0, width: 10.8, height: 5.0), cornerSize: CGSize(width: 2.4, height: 2.4))
        return ChefDrawing.finish(path, isHalo: false, in: rect)
    }
}

/// The toque: a band and three puffs. It is the one shape that says "cook", so it gets the most
/// canvas after the pot, and its halo is what draws the hairline between hat and face.
private struct ChefHat: Shape {
    var isHalo = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: 3.8, y: 1.0, width: 5.0, height: 5.0))
        path.addEllipse(in: CGRect(x: 7.1, y: 0.2, width: 5.8, height: 5.8))
        path.addEllipse(in: CGRect(x: 11.2, y: 1.0, width: 5.0, height: 5.0))
        path.addRoundedRect(in: CGRect(x: 5.6, y: 3.8, width: 8.8, height: 2.8), cornerSize: CGSize(width: 0.9, height: 0.9))
        return ChefDrawing.finish(path, isHalo: isHalo, in: rect)
    }
}

/// The spoon, handle up out of the pot with a knob on the end so it reads as a utensil and not a
/// stray line. Its bowl is in the stew, so the pot hides it. `AgentChefIcon` turns the whole
/// thing around the pivot.
private struct ChefSpoon: Shape {
    var isHalo = false

    func path(in rect: CGRect) -> Path {
        var path = ChefDrawing.limb(
            from: ChefDrawing.spoonPivot,
            to: CGPoint(x: 18.9, y: 4.6),
            width: 2.0
        )
        // A zero-length stroke is a circle whose outline winds the same way as the handle's, so
        // the two fill as one piece; an ellipse wound the other way cuts a slot where they cross.
        path.addPath(ChefDrawing.limb(
            from: CGPoint(x: 18.9, y: 4.6),
            to: CGPoint(x: 18.9, y: 4.6),
            width: 3.4
        ))
        return ChefDrawing.finish(path, isHalo: isHalo, in: rect)
    }
}

/// The pot: a rim wider than the body, spanning nearly the whole square. Its size is what keeps
/// the icon legible from a distance, so it stays the biggest single mass in the drawing.
private struct ChefPot: Shape {
    var isHalo = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 2.6, y: 14.6, width: 18.8, height: 2.6), cornerSize: CGSize(width: 1.0, height: 1.0))
        path.addRoundedRect(in: CGRect(x: 4.4, y: 16.4, width: 15.2, height: 6.8), cornerSize: CGSize(width: 2.0, height: 2.0))
        return ChefDrawing.finish(path, isHalo: isHalo, in: rect)
    }
}
