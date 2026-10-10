import MyTermCore
import SwiftUI

public struct AgentIndicatorPicker<Icon: Hashable & CaseIterable, Glyph: View>: View where Icon.AllCases: RandomAccessCollection {
    private let title: String
    private let caption: String
    @Binding private var icon: Icon
    @Binding private var color: WorkspaceColor
    private let displayName: (Icon) -> String
    private let reset: () -> Void
    private let glyph: (Icon, Color, CGFloat) -> Glyph

    public init(
        title: String, caption: String, icon: Binding<Icon>, color: Binding<WorkspaceColor>,
        displayName: @escaping (Icon) -> String, reset: @escaping () -> Void,
        @ViewBuilder glyph: @escaping (Icon, Color, CGFloat) -> Glyph
    ) {
        self.title = title
        self.caption = caption
        _icon = icon
        _color = color
        self.displayName = displayName
        self.reset = reset
        self.glyph = glyph
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.Font.ui(13, weight: .medium))
                    Text(caption).font(Theme.Font.ui(12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Text("Workbench · data source").lineLimit(1)
                    glyph(icon, color.indicatorColor, 16)
                }
                .font(Theme.Font.ui(12))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.sidebarGround, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
                Button("Reset", action: reset)
                    .accessibilityLabel("Reset \(title.lowercased()) indicator")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 10), spacing: 6) {
                ForEach(Array(Icon.allCases), id: \.self) { choice in
                    Button { icon = choice } label: {
                        glyph(choice, color.indicatorColor, 20)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(icon == choice ? Theme.accent.opacity(0.12) : Theme.surfaceRaised,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(icon == choice ? Theme.accent : Theme.hairlineStrong, lineWidth: 1))
                            .shadow(color: icon == choice ? Theme.accent.opacity(0.18) : .clear, radius: 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(displayName(choice))
                    .accessibilityAddTraits(icon == choice ? .isSelected : [])
                    #if os(macOS)
                    .help(displayName(choice))
                    #endif
                }
            }
            .accessibilityRepresentation {
                Picker("\(title) icon", selection: $icon) {
                    ForEach(Array(Icon.allCases), id: \.self) { choice in
                        Text(displayName(choice)).tag(choice)
                    }
                }
                #if os(macOS)
                .pickerStyle(.radioGroup)
                #endif
            }
            HStack(spacing: 8) {
                ForEach(WorkspaceColor.allCases, id: \.self) { choice in
                    Button { color = choice } label: {
                        Circle().fill(choice.indicatorColor)
                            .frame(width: 22, height: 22)
                            .padding(3)
                            .overlay(Circle().strokeBorder(color == choice ? Theme.textPrimary : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.rawValue.capitalized)
                    .accessibilityAddTraits(color == choice ? .isSelected : [])
                    #if os(macOS)
                    .help(choice.rawValue.capitalized)
                    #endif
                }
            }
            .accessibilityRepresentation {
                Picker("\(title) colour", selection: $color) {
                    ForEach(WorkspaceColor.allCases, id: \.self) { choice in
                        Text(choice.rawValue.capitalized).tag(choice)
                    }
                }
                #if os(macOS)
                .pickerStyle(.radioGroup)
                #endif
            }
        }
    }
}
