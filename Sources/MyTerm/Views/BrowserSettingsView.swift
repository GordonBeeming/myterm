import MyTermCore
import MyTermPlatform
import SwiftUI

struct BrowserSettingsView: View {
    @Bindable var settings: BrowserSettingsStore

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
                Text(PasskeyCapability.isEnabled
                    ? "Enabled. MyTerm passes requests to macOS and never stores passkeys; your chosen credential provider handles them."
                    : "Not enabled in this build. MyTerm never stores passkeys; a signed build needs Apple's browser entitlement to pass requests to your credential provider.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 440)
    }
}
