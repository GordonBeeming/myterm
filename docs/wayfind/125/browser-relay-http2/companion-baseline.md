# Companion proxy baseline on iPhone and iPad

The native proxy suite passed 11 tests on each disposable iOS 27.0 Simulator (build 24A5408d). The suite covers an encrypted SOCKS5 fixture, a hostname resolved by the remote end of the tunnel, WebSocket delivery and blocking of literal loopback subresources and navigation. These tests exercise Companion's current path. They do not connect to a production Rust server.

| Simulator | Pass | Fail | Skip | Client-local STUN datagrams |
| --- | ---: | ---: | ---: | ---: |
| iPhone | 11 | 0 | 0 | 5 |
| iPad | 11 | 0 | 0 | 5 |

The WebRTC test records the number of datagrams without asserting that the count is zero. Its passing result and observed traffic confirm that the current proxy does not contain WebRTC, even without a camera or microphone permission request. The [WebRTC containment task](https://github.com/GordonBeeming/myterm/issues/206) tracks the change and acceptance check. WebKit exposes a peer-connection toggle in its private header, so it is not a supported app API. [WebKit private declaration](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKPreferencesPrivate.h)

For the iPad, Xcode used an unsigned build. The first unsigned iPhone test host failed to launch. After a completed headless boot, the ad-hoc signed iPhone run executed the full suite. A separate attempt to create a fresh iOS 27.1 simulator with the selected model failed as incompatible.

To repeat, use a disposable simulator with a compatible runtime and a fresh result path. The settings below are the successful iPhone configuration.

```sh
xcrun simctl bootstatus "$simulator_id" -b
xcodebuild test -project Companion/MyTermCompanion.xcodeproj -scheme MyTermCompanion \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$scratch/build" -resultBundlePath "$scratch/proxy.xcresult" \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:MyTermCompanionTests/RemoteBrowserProxyWebViewTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-
```

A proxy-only browser on Apple platforms can use alternate hostnames for remote development sites. OuterSSH documents an implementation with hostname and content rewriting, including gaps for some dynamically generated URLs. The rewritten hostname becomes the browser's origin and still needs a matching certificate. This is compatibility research for a potential scope decision. The current MyTerm contract requires exact-origin loopback routing. [OuterSSH implementation and limits](https://outerssh.org/compatibility-hacks/)
