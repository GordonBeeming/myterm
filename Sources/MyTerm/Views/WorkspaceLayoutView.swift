import AppKit
import MyTermCore
import SwiftUI

struct WorkspaceTabContentView: View {
    let model: AppModel

    var body: some View {
        let workspace = model.selectedWorkspace
        Group {
            if let group = model.maximizedTabGroup {
                PaneGroupView(model: model, workspaceID: workspace.id, group: group)
                    .id(group.id)
            } else {
                WorkspaceLayoutView(model: model, workspaceID: workspace.id, layout: workspace.layout)
            }
        }
            .id(workspace.id)
    }
}

private struct WorkspaceLayoutView: View {
    let model: AppModel
    let workspaceID: WorkspaceID
    let layout: WorkspaceLayout

    var body: some View {
        switch layout {
        case .group(let group):
            PaneGroupView(model: model, workspaceID: workspaceID, group: group).id(group.id)
        case .split(let id, let orientation, let children, let weights):
            ResizableWorkspaceSplitView(
                model: model,
                workspaceID: workspaceID,
                splitID: id,
                orientation: orientation,
                children: children,
                weights: weights
            )
            .id(id)
        }
    }
}

enum WorkspaceSplitRatioResolver {
    static func normalizedWeights(_ weights: [Double]) -> [Double] {
        WorkspaceLayout.normalizedWeights(weights, count: weights.count)
    }

    static func adjusting(
        _ weights: [Double],
        dividerAt index: Int,
        translation: CGFloat,
        availableLength: CGFloat
    ) -> [Double] {
        guard weights.indices.contains(index), weights.indices.contains(index + 1), availableLength > 0 else {
            return normalizedWeights(weights)
        }
        var resolved = normalizedWeights(weights)
        let delta = Double(translation / availableLength)
        let minimum = min(0.08, (resolved[index] + resolved[index + 1]) / 2)
        let left = min(max(resolved[index] + delta, minimum), resolved[index] + resolved[index + 1] - minimum)
        resolved[index + 1] += resolved[index] - left
        resolved[index] = left
        return normalizedWeights(resolved)
    }
}

private struct ResizableWorkspaceSplitView: View {
    let model: AppModel
    let workspaceID: WorkspaceID
    let splitID: SplitNodeID
    let orientation: SplitOrientation
    let children: [WorkspaceLayout]
    let weights: [Double]
    @State private var dragWeights: [Double]?

    private static let dividerThickness: CGFloat = 11

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let length = orientation == .horizontal ? size.width : size.height
            let resolvedWeights = dragWeights ?? WorkspaceSplitRatioResolver.normalizedWeights(weights)
            let availableLength = max(0, length - Self.dividerThickness * CGFloat(max(0, children.count - 1)))
            let childLengths = resolvedWeights.map { CGFloat($0) * availableLength }

            if orientation == .horizontal {
                HStack(spacing: 0) { splitChildren(lengths: childLengths, crossLength: size.height, availableLength: availableLength) }
            } else {
                VStack(spacing: 0) { splitChildren(lengths: childLengths, crossLength: size.width, availableLength: availableLength) }
            }
        }
    }

    @ViewBuilder
    private func splitChildren(lengths: [CGFloat], crossLength: CGFloat, availableLength: CGFloat) -> some View {
        ForEach(Array(children.enumerated()), id: \.offset) { index, child in
            WorkspaceLayoutView(model: model, workspaceID: workspaceID, layout: child)
                .frame(
                    width: orientation == .horizontal ? lengths[index] : crossLength,
                    height: orientation == .vertical ? lengths[index] : crossLength
                )
                .clipped()
            if index < children.count - 1 { divider(index: index, availableLength: availableLength) }
        }
    }

    private func divider(index: Int, availableLength: CGFloat) -> some View {
        WorkspaceSplitDivider(orientation: orientation, adjust: { adjustDivider(index: index, direction: $0) })
            .frame(
                width: orientation == .horizontal ? Self.dividerThickness : nil,
                height: orientation == .vertical ? Self.dividerThickness : nil
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let translation = orientation == .horizontal ? value.translation.width : value.translation.height
                        dragWeights = WorkspaceSplitRatioResolver.adjusting(
                            weights,
                            dividerAt: index,
                            translation: translation,
                            availableLength: availableLength
                        )
                    }
                    .onEnded { _ in
                        guard let dragWeights else { return }
                        model.updateSplitWeights(splitID: splitID, weights: dragWeights)
                        self.dragWeights = nil
                    }
            )
            .accessibilityLabel("Resize panes")
            .accessibilityValue("\(Int((normalizedDividerValue(index: index) * 100).rounded())) percent")
            .help("Drag to resize panes")
    }

    private func normalizedDividerValue(index: Int) -> Double {
        WorkspaceSplitRatioResolver.normalizedWeights(dragWeights ?? weights).prefix(index + 1).reduce(0, +)
    }

    private func adjustDivider(index: Int, direction: AccessibilityAdjustmentDirection) {
        let translation: CGFloat = direction == .increment ? 24 : -24
        let updated = WorkspaceSplitRatioResolver.adjusting(
            dragWeights ?? weights,
            dividerAt: index,
            translation: translation,
            availableLength: 240
        )
        dragWeights = updated
        model.updateSplitWeights(splitID: splitID, weights: updated)
        dragWeights = nil
    }
}

private struct WorkspaceSplitDivider: View {
    let orientation: SplitOrientation
    let adjust: (AccessibilityAdjustmentDirection) -> Void

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: orientation == .horizontal ? 1 : nil, height: orientation == .vertical ? 1 : nil)
        }
        .onHover { isHovering in
            guard isHovering else { NSCursor.arrow.set(); return }
            (orientation == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        }
        .focusable()
        .onMoveCommand { direction in
            guard let adjustment = WorkspaceSplitKeyboardAdjustment.adjustment(for: direction, orientation: orientation) else { return }
            adjust(adjustment)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction(adjust)
    }
}

enum WorkspaceSplitKeyboardAdjustment {
    static func adjustment(for direction: MoveCommandDirection, orientation: SplitOrientation) -> AccessibilityAdjustmentDirection? {
        switch (orientation, direction) {
        case (.horizontal, .left), (.vertical, .up): .decrement
        case (.horizontal, .right), (.vertical, .down): .increment
        default: nil
        }
    }
}
