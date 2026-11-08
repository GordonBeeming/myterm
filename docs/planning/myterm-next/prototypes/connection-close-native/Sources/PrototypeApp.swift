import SwiftUI

@main
struct ConnectionClosePrototypeApp: App {
    var body: some Scene {
        WindowGroup("MyTerm • Connection prototype") {
            PrototypeView()
                .frame(minWidth: 320, minHeight: 600)
        }
    }
}
