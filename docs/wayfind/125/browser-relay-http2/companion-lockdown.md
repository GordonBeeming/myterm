# WebRTC containment in Companion’s native proxy

[The Companion patch](companion-lockdown.patch) enables WebKit Lockdown when creating each native proxy view, before its first navigation. The view keeps the existing encrypted proxy and destination checks. Popup links that Companion handles in the same view inherit the policy. There is no per-domain exception to Lockdown. [Apple’s per-view setting](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/islockdownmodeenabled) · [Accepted compatibility trade-off](https://github.com/GordonBeeming/myterm/issues/206#issuecomment-7099737405)

The acceptance test opens two HTTP documents in succession through Companion’s encrypted SOCKS5 fixture. Each document and its same-origin iframe must load without exposing either the standard or legacy-prefixed peer-connection constructor. An uncached request succeeds before shutdown, then fails without reaching the fixture after both ends of the tunnel stop. The current document and frame stay loaded and the test checks WebRTC again. An ordinary WebKit control uses the same proxy configuration with a separate website data store and must produce a direct datagram from an attempted data channel. Neither test requests media permissions.

## Results

Both runs used Xcode 27.2 (27B52) and the iOS 27.0 Simulator runtime (24A5408d).

| Client | Passed | Failed | Skipped | Protected view datagrams | Control datagrams before succeeding |
| --- | ---: | ---: | ---: | ---: | ---: |
| iPhone 17 Pro Simulator | 12 | 0 | 0 | 0 | 1 |
| iPad Pro 11-inch (M5) Simulator | 12 | 0 | 0 | 0 | 1 |

The suite also passed HTTP hostname routing, WebSocket message delivery, and the existing literal-loopback navigation and subresource checks.

## Repeat the Companion suite

Start from `9b95f8d` or another revision with compatible Companion sources. Retrieve the patch from the wayfinding branch and apply it in the checkout under test. Set `simulator_id` to the UUID of a disposable iPhone or iPad Simulator and use a fresh scratch directory per run.

```sh
git show origin/gb/docs/wayfind-125:docs/wayfind/125/browser-relay-http2/companion-lockdown.patch | git apply
scratch=$(mktemp -d /private/tmp/myterm-companion-lockdown.XXXXXX)
xcrun simctl bootstatus "$simulator_id" -b
xcodebuild test -project Companion/MyTermCompanion.xcodeproj -scheme MyTermCompanion \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$scratch/build" -resultBundlePath "$scratch/proxy.xcresult" \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:MyTermCompanionTests/RemoteBrowserProxyWebViewTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-
```

## Coverage boundary

The [macOS WebKit fixture](webrtc-lockdown.md) exercised the same setting over trusted HTTP/3 with a working positive control. The compatibility tests cover HTTPS login, WebSockets and native transfers. They also record loss of access to IndexedDB and FileReader on Mac and iPhone Simulator and loss of Service Worker exposure on Mac. The Companion suite exercises the app’s native proxy over a disposable encrypted Swift tunnel fixture on one Mac. The redesigned Mac client, production Rust servers and physical iPhone and iPad runs still require acceptance. Cross-origin iframe coverage is also open.
