# Companion browser prototype

Open a browser tab from a paired Mac in the iPhone or iPad companion. The selector above the address bar switches between **Native proxy** and **Mac rendered**. Both devices need a build with this feature. Pairing and relay sign-in use the existing setup; users do not install a VPN profile or a certificate.

For a development build, run the Mac host from this checkout and open `Companion/MyTermCompanion.xcodeproj` in Xcode. Select the `MyTermCompanion` scheme and an iPhone or iPad destination. Connect both apps to the same relay and pair them, then open a browser tab on the Mac and select it in the companion.

Native proxy renders the page on the companion and carries browser TCP connections to the Mac through the existing authenticated, end-to-end encrypted relay channel. It supports normal touch scrolling and text selection. Each browser uses an authenticated loopback proxy with direct fallback disabled.

WebKit bypasses both HTTP CONNECT and SOCKS proxies for loopback addresses on the tested systems. Native mode therefore blocks localhost and IP-literal navigation and subresources. Tabs with those addresses start in Mac rendered mode.

The Mac also checks every native connection's DNS answers. It rejects private, loopback, link-local, reserved, and local-interface addresses, including mixed public/private answers, then connects to the vetted numeric address. This prevents a public hostname from rebinding to a private service. Use Mac rendered mode for private-network websites or pages that need blocked resources. Scoped artifact servers retain their separate session capability checks.

WebRTC uses a separate network path. An iPhone simulator test observed device-local STUN packets even with the native proxy configured. Native mode does **not** guarantee that every kind of page traffic originates on the Mac. Use Mac rendered mode when that guarantee matters.

Mac rendered runs a separate browser on the source Mac. The companion receives bounded JPEG frames and sends input through the encrypted relay. The viewport adapts to the phone or iPad. Tap a field, use the text box below the page to enter text, then press Send. Enter, Backspace, and Tab controls are beside it. Swiping scrolls the page. This prototype refreshes periodically, so it has more latency than native browsing and does not provide native page text selection, accessibility, or audio streaming.

Mac rendered declines camera and microphone access, file-upload panels, and JavaScript confirmation or prompt dialogs. Those interactions need companion controls before they can be supported. Native tunnel streams close after two minutes without traffic; applications with idle WebSockets need to reconnect.

## Local artifacts

Open the artifact as a browser tab on the Mac, then select that tab in the companion. Both modes can read the selected file and resources under its containing directory. Access outside that directory, symlinks, hidden files, and writes are rejected. The workspace's local-file JavaScript setting still applies. Enable it on the Mac when an interactive artifact requires scripts.

Artifact servers bind only to loopback and enforce session-specific access. The relay sees encrypted messages, including page URLs, artifact contents, screenshots, and typed input. It does not terminate the end-to-end browser channel. An HTTP origin remains HTTP between the source Mac and that origin; HTTPS continues to use the browser's normal certificate validation.

A sleeping or disconnected Mac makes both modes unavailable.

## Sign-ins and cookies

Both modes share one cookie jar per browser profile, so signing in on the Mac signs you in on the companion and the other way round. Switching between Native proxy and Mac rendered keeps the session.

The boundary is the workspace's **Browser data** setting, the same one the Mac's own browser tabs use. Two workspaces on separate profiles keep separate sign-ins on the phone too, and changing the scope on the Mac moves the companion with it.

Mac rendered already runs in the Mac's own profile. Native proxy keeps its own persistent store on the device, inside the app container under iOS data protection. The companion keeps the two in step over the encrypted channel: it asks for the Mac's cookies when it opens a tab, and sends its own back after each page load and when the tab closes. The relay only ever sees ciphertext.

`Share sign-ins with companion`, under Browser sessions in Settings, controls this per workspace, folder, or globally. It is on by default. Turn it off and nothing crosses the link for that workspace. The companion still keeps a persistent jar, so its sign-ins survive a mode switch; they just stay on the phone. Removing a pairing deletes that Mac's jars from the device.

Signing in to the same site on both devices at once means whichever copy transfers last wins. And only one web view can hold a profile's store at a time, so opening a second native-proxy tab on the same profile takes the session from the first, which then asks you to reload.

## Workspaces inside folders

Use the plus button beside an existing folder heading in the companion. The new workspace belongs to that folder and inherits its settings. Later changes to folder preferences still apply. The Mac's current workspace selection is preserved.

## Development checks

From the repository root:

```sh
swift test
swift test --package-path Packages/MyTermRemote
```

`CompanionHostIntegrationTests` starts the production Go relay handler with disposable test credentials, pairs a client, and exercises both browser paths alongside terminal control. The origin and artifact files are temporary. Test-only TLS trust is scoped to the fixture certificate.

To include a public HTTPS origin in that check, run `MYTERM_BROWSER_TEST_PUBLIC_HTTPS=1 swift test --filter CompanionHostIntegrationTests`. This optional check needs internet access. The relay service itself needs no protocol change for these browser messages.

Run companion browser checks on an available simulator:

```sh
xcodebuild test \
  -project Companion/MyTermCompanion.xcodeproj \
  -scheme MyTermCompanion \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -only-testing:MyTermCompanionTests/RemoteBrowserTests \
  -only-testing:MyTermCompanionTests/RemoteBrowserProxyWebViewTests \
  -collect-test-diagnostics never \
  CODE_SIGNING_ALLOWED=NO
```

These checks load a real page through the native proxy, verify that a stopped proxy cannot fall back to a direct connection, test blocked device-local resources, and record the WebRTC networking boundary. The Mac renderer tests verify visible page content and trusted input in a cross-origin iframe.
