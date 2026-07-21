import MyTermCore
import MyTermPlatform
import SwiftUI

struct BrowserSettingsView: View {
    @Bindable var settings: BrowserSettingsStore
    @State private var passkeyAccess = PasskeyAccessController()

    var body: some View {
        Form {
            Picker("Browser data", selection: $settings.browserDataScope) {
                ForEach([BrowserDataScope.appWide, .workspace, .projectDirectory], id: \.self) { scope in
                    Text(scope.browserDataScopeLabel).tag(scope)
                }
            }

            Text("New browser tabs use this profile. Existing tabs keep their current profile.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Section("Passkeys") {
                Text(passkeyDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if passkeyAccess.state == .notDetermined {
                    Button("Allow passkey access") {
                        passkeyAccess.requestAccess()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 440)
    }

    private var passkeyDescription: String {
        switch passkeyAccess.state {
        case .unavailable:
            "Not enabled in this build. MyTerm never stores passkeys; a signed build needs Apple's browser entitlement to pass requests to your credential provider."
        case .notDetermined:
            "MyTerm never stores passkeys. Allow access so WebKit can pass website requests to your chosen credential provider."
        case .denied:
            "Passkey access is denied. MyTerm never stores passkeys; macOS and your chosen credential provider handle them."
        case .authorized:
            "Enabled. MyTerm passes website requests to macOS and never stores passkeys; your chosen credential provider handles them."
        }
    }
}
