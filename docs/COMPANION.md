# iPhone and iPad companion

The companion connects to running myterm apps through an HTTPS relay you operate. Each Mac owns its terminal processes and workspace state. Closing myterm, sleeping the Mac, or losing its connection makes that host unavailable. The relay does not run replacement shells.

The initial app targets iOS and iPadOS 27.0. Platform behavior follows [Apple's iOS and iPadOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes). The separate iPhone Duo layout milestone requires the 27.1 SDK and device validation before it can ship.

## Build and test

Use Xcode 27 with the iOS 27 SDK and its Metal component. CI uses GitHub's [Xcode 27 preview runner](https://github.blog/changelog/2026-09-10-xcode-27-runner-image-now-runs-on-macos-27/). Check the selected installation with:

```sh
bash script/verify_companion_toolchain.sh 27.0
```

If Xcode reports a missing Metal component, install it with `xcodebuild -downloadComponent MetalToolchain`. After upgrading Xcode, finish its component setup before running simulator tests. Changing `DEVELOPER_DIR` for one command allows a particular installation to be used without changing the machine's default selection.

The checked-in Xcode project is generated from `Companion/project.yml`. After changing that definition, regenerate it with:

```sh
xcodegen generate --spec Companion/project.yml --project Companion
```

Run the native protocol tests and the phone/tablet suites:

```sh
swift test --package-path Packages/MyTermRemote
COMPANION_DEVICE_FAMILY=iPhone bash script/test_companion.sh
COMPANION_DEVICE_FAMILY=iPad bash script/test_companion.sh
```

The simulator script creates a dedicated device, saves an `.xcresult` under `dist`, and deletes that device afterward. `COMPANION_SIMULATOR_UDID` selects an explicitly supplied device instead; the script never deletes a supplied device. Move previous result bundles before rerunning. Set `COMPANION_KEEP_SIMULATOR=1` when an automatically created device needs further inspection.

Existing desktop validation remains `swift test --parallel`, `bash script/channel_isolation_test.sh`, and `make verify`. Use `--bundle` when running the desktop build script without launching the app. Normal launches now focus the existing healthy instance. Quit it explicitly before launching a rebuilt version.

## Deploy a relay

Follow [the relay deployment instructions](../Services/relay/README.md). The service needs a stable DNS name, trusted HTTPS, and persistent SQLite storage. Its container and Caddy example are included with its source. Keep the relay's HTTP listener behind the HTTPS proxy.

Run `bootstrap-owner` on the relay server to create an expiring enrollment link. Enter the relay origin and that link in the Mac app's Companion settings, then complete passkey registration in the system browser. The link's secret stays in its URL fragment and is sent only to the registration endpoint over HTTPS.

Subsequent sign-ins use the passkey stored by Apple Passwords or another credential provider. The relay stores public credential records, not passkey private keys. `add-passkey` creates an additional enrollment link. `recover-owner` replaces the owner's credentials and revokes existing relay sessions after the new credential is verified; sign the apps in again afterward.

LAN-only hosting uses the same flow. It still requires a hostname and a certificate trusted by the phone. A QR code supplies connection details but does not bypass TLS validation.

## Pair and use a Mac

Connect the Mac to its relay and start Pair Mode in Companion settings. Scan that QR code in the phone app, or paste the pairing link when using a simulator. Complete relay sign-in, then approve the phone on the Mac.

The pairing ticket is generated and consumed on the Mac. The relay forwards encrypted pairing messages. Paired devices retain the peer's public keys and establish a fresh authenticated session on each connection.

Save several Macs, including Macs using different relays. The connection picker checks reachability independently. The expanded layout includes a workspace sidebar; compact layouts navigate into a workspace and then a terminal. The desktop's workspace and pane-group identities remain authoritative while each companion scene keeps its own selection.

One connection controls a terminal's input and dimensions. Other connections can view it. Take Control explicitly transfers that lease. Detaching a mobile view leaves the process running on the Mac. Disconnecting disables input; uncertain keystrokes are never queued for replay.

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
