import MyTermRemoteProtocol
import SwiftUI
import UIKit

/// A browser tab is the Mac's window onto a URL. The device opens the same URL itself rather than
/// mirroring pixels, so there is nothing here to attach to.
struct BrowserTabScreen: View {
    let tab: RemoteTab

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "globe")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(tab.title)
                .font(.headline)
            if let url = tab.url {
                Text(url)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open in Safari") {
                    openInSafari(url)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .navigationTitle(tab.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func openInSafari(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview {
    NavigationStack {
        BrowserTabScreen(tab: RemoteTab(
            id: "preview",
            kind: .browser,
            title: "Preview",
            url: "https://ssw.com.au"
        ))
    }
}
