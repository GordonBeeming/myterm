# iPhone and iPad companion

The companion connects to running myterm apps through an HTTPS relay you operate. Each Mac owns its terminal processes and workspace state. Closing myterm, sleeping the Mac, or losing its connection makes that host unavailable. The relay does not run replacement shells.

The app supports iOS and iPadOS 26 or later. Adaptive panes respond to the available window size. Device-specific iPhone Duo layout work still requires its own SDK and device validation.

## Build and test

Use Xcode 27.0 or newer with its matching Metal component. CI pins Xcode 27.0 on GitHub’s [xcode-27 runner](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md), which is still a public preview. Check the selected installation with:

```sh
bash script/verify_companion_toolchain.sh 27.0
```

If Xcode reports a missing Metal component, install it with `xcodebuild -downloadComponent MetalToolchain`. After upgrading Xcode, finish its component setup before running simulator tests. Changing `DEVELOPER_DIR` for one command allows a particular installation to be used without changing the machine's default selection.

The checked-in Xcode project is generated from `Companion/project.yml`. After changing that definition, regenerate it with:

```sh
xcodegen generate --spec Companion/project.yml --project Companion
```

For a physical device, copy `Companion/Support/Local.xcconfig.example` to `Companion/Support/Local.xcconfig` and set `TEAM_ID` to your Apple development team ID. Both the app and notification extension use this local, Git-ignored configuration. Select your Apple account in Xcode and allow automatic signing to create the required provisioning profiles. The extension needs the shared App Group as well as the app.

### Local dev installs and TestFlight

Use Debug when installing directly from Xcode. Debug installs as **MyTerm Dev** with bundle ID `com.gordonbeeming.myterm.companion.dev`; its notification extension, app group, keychain group, and URL scheme are also separate. Release/TestFlight keeps `com.gordonbeeming.myterm.companion`. Only the Release app needs an App Store Connect record.

Automatic signing must provision the Debug app and extension IDs and the `group.com.gordonbeeming.myterm.companion.dev` App Group for your team. Pair the Debug app separately; it does not read production credentials or saved connections. Use a relay version that supports `myterm-companion-dev://auth/callback` and scan the QR in the app you intend to pair. Older production pairing links remain supported.

If an older Debug build replaced the TestFlight app, reinstall production from TestFlight, then install the updated Debug build from Xcode. The new identities allow both apps to coexist; reinstalling cannot undo any data changes made by the older shared-identity build.

Run the native protocol tests and the phone/tablet suites:

```sh
swift test --package-path Packages/MyTermRemote
COMPANION_DEVICE_FAMILY=iPhone bash script/test_companion.sh
COMPANION_DEVICE_FAMILY=iPad bash script/test_companion.sh
```

The native interoperability tests also require Go. They compile a temporary relay fixture before starting its readiness check; the service modules declare the minimum Go version.

The simulator script chooses an installed runtime matching the selected Xcode SDK’s major version, creates a dedicated device, saves an `.xcresult` under `dist`, and deletes that device afterward. `COMPANION_SIMULATOR_UDID` selects an explicitly supplied device instead; the script never deletes a supplied device. Move previous result bundles before rerunning. Set `COMPANION_KEEP_SIMULATOR=1` when an automatically created device needs further inspection.

Existing desktop validation remains `swift test --parallel`, `bash script/channel_isolation_test.sh`, and `make verify`. Use `--bundle` when running the desktop build script without launching the app. Normal launches now focus the existing healthy instance. Quit it explicitly before launching a rebuilt version.

## Deploy a relay

For dev and prod on one Linux server behind cloudflared, follow [the Cloudflare proxy setup guide](PROXY_SETUP.md). It covers containers, tunnel routes, passkeys, pairing, backups, and upgrades without managing certificates on the server.

Follow [the relay deployment instructions](../Services/relay/README.md). The service needs a stable DNS name, trusted HTTPS, and persistent SQLite storage. Its container and Caddy example are included with its source. Keep the relay's HTTP listener behind the HTTPS proxy.

Run `bootstrap-owner` on the relay server to create an expiring enrollment link. Paste it into the Mac app's Companion settings; MyTerm fills the relay address from the link. Check the address, then complete passkey registration in the system browser. The link's secret stays in its URL fragment and is sent only to the registration endpoint over HTTPS.

Subsequent sign-ins use the passkey stored by Apple Passwords or another credential provider. The relay stores public credential records, not passkey private keys. `add-passkey` creates an additional enrollment link. `recover-owner` replaces the owner's credentials and revokes existing relay sessions after the new credential is verified; sign the apps in again afterward.

LAN-only hosting uses the same flow. It still requires a hostname and a certificate trusted by the phone. A QR code supplies connection details but does not bypass TLS validation.

## Pair and use a Mac

Connect the Mac to its relay and start Pair Mode in Companion settings. Scan that QR code in the phone app, or paste the pairing link when using a simulator. Complete relay sign-in, then approve the phone on the Mac.

The QR code refreshes every 30 seconds; each code remains valid for 60 seconds so sign-in can finish across a refresh. The pairing ticket is generated and consumed on the Mac. The relay forwards encrypted pairing messages. Paired devices retain the peer's public keys and establish a fresh authenticated session on each connection.

Save several Macs, including Macs using different relays. The connection picker checks reachability independently. By default, wider screens mirror the Mac's pane arrangement and split proportions. Narrow screens show one terminal at a time. A row of pane chips sits above it, with a second row for that pane's terminals when it holds more than one. A workspace opens on its first pane, then reopens on whichever pane you last chose on that device. Settings → Workspace view can switch this device back to the terminal list. The desktop's workspace and pane-group identities remain authoritative while each companion scene keeps its own tab and focus selection. Extra terminal-key rows are hidden by default. The keyboard button in the terminal toolbar shows or hides them and remembers the choice on this device.

Opening a terminal starts in view-only mode. Use **Request control** or **Take control** explicitly to control its input and dimensions. Other connections keep viewing it. Take Control explicitly transfers that lease. After the Mac yields control, its input stays paused even if the companion releases control or disconnects; click **Take Control** on the Mac to resume local input. Known late input/resize packets from a former controller are rejected without disconnecting the viewer. Detaching a mobile view leaves the process running on the Mac. Disconnecting disables input; uncertain keystrokes are never queued for replay.

The terminal follows live output even in view-only mode. Scrolling up pauses following so you can read earlier output. **Jump to live** resumes it. Each device keeps its own reading position through screen updates, keyboard changes, and reconnects, without resizing the Mac's terminal while viewing.

Use **Compose** beside the control button to write a longer prompt or command in a native text editor. **Insert into terminal** pastes the text; **Insert + Enter** also sends Return. Sending requires control, but drafting does not. Drafts stay in the current app window until cleared, including after insertion or dismissal. They are not saved across app restarts. Terminals that support bracketed paste receive the text as a paste; the composer warns when multiple lines may run commands in a terminal without that support.

Browser tabs expose their titles and URLs in this version. Opening the same URL elsewhere does not transfer the Mac browser's cookies or page state.

## Notifications

The shared [push gateway](../Services/push-gateway/README.md) sends APNs notifications for the distributed companion app. It is separate from user-operated relays. Its Apple signing key must never be distributed to relay operators or included in a container image.

Enable Push Notifications and App Attest for the companion's App ID. Configure the app and notification extension's shared Keychain group. Development builds use development entitlements; TestFlight and App Store builds use production entitlements. Set the developer team and push-gateway origin in the Xcode build configuration before archiving.

The phone proves its app identity through App Attest and confirms ownership of its APNs token. It then grants a paired Mac permission to notify that recipient. Notification content is encrypted for the phone and signed by the Mac. The extension decrypts it using its shared Keychain material; a generic alert remains when decryption cannot finish.

APNs delivery is best effort. A gateway outage does not stop terminal connections. Notification taps select the saved connection and terminal, or show that the host is offline.

A signed physical-device enrollment and delivery test is required before release. Simulator tests and generated cryptographic fixtures do not prove Apple push delivery.

## Protocol and dependency maintenance

- [Native transport and pairing](../Packages/MyTermRemote/README.md)
- [Relay HTTP and WebSocket contract](../Services/relay/protocol.md)
- [Push gateway contract](../Services/push-gateway/protocol.md)
- [SwiftTerm source provenance](../Vendor/SwiftTerm/UPSTREAM.md)

Keep terminal checkpoints versioned with their engine state. An unsupported checkpoint must fail explicitly; a short text preview cannot restore a full-screen terminal application.
