import MyTermCore
import SwiftUI

struct ActiveTabView: View {
    let model: AppModel

    var body: some View {
        WorkspaceTabContentView(model: model)
    }
}
