import MyTermCore
import SwiftUI

extension WorkspaceColor {
    /// The one place a stored colour name becomes a drawable colour. The sidebar, the workspace
    /// background, and the swatch on a notification all read it from here.
    var swiftUIColor: Color {
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
