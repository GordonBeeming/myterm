# Native browser routing evidence

Work in progress for [Validate proxy-only browser routing and native workflow parity](https://github.com/GordonBeeming/myterm/issues/160). The ticket remains open. This probe rejects one candidate mechanism; it does not select a replacement architecture.

## Observed on this machine

On macOS 27.3 (26C5035r), compiled with Xcode 27.2 (27B52), an offscreen native `WKWebView` using a nonpersistent website store and an HTTP CONNECT proxy routes an ordinary `.invalid` hostname through the proxy fixture. The same configuration sends `localhost`, `127.0.0.1` and `[::1]` requests directly to the client-local origin fixture. All four loads finish successfully.

The proxy has `allowFailover = false`, `excludedDomains = []` and `matchDomains = ["localhost", "127.0.0.1", "::1", ""]`. No MyTerm destination policy or content blocker participates, so those application controls cannot explain the bypass.

The fixture records both connection paths and returns different document titles. Both fixtures run on this Mac with ephemeral listener ports. The proxy returns a fixture response after CONNECT; it does not forward to a remote server. This checks WebKit's choice of route only. It proves neither Rust integration nor encryption or cross-machine browsing.

[Raw results](macos-http-connect-results.json) record each URL, loaded title, proxy requests and direct origin requests.

## Reproduce without opening a window

From the repository root:

```sh
swiftc -parse-as-library -swift-version 5 script/browser-routing-probe/main.swift -o /tmp/myterm-browser-routing-probe -framework AppKit -framework WebKit -framework Network
/tmp/myterm-browser-routing-probe
```

The executable creates no windows, uses `NSApplication`'s prohibited activation policy and changes no system proxy settings. All website stores are nonpersistent. It prints JSON and stops its listeners on completion. If the positive control fails or any load times out, inspect that result before interpreting the other cases.

## Existing regression baseline

```sh
swift test --scratch-path /tmp/myterm-browser-contract-build --filter 'NativeBrowserDestinationPolicyTests|BrowserDataProfilesTests|CompanionExternalBrowserAuthenticationTests'
```

Observed: 25 tests passed, 0 failed: destination policy (3), browser profiles/settings (16), external authentication callbacks (6). The [suite summary](regression-summary.log) retains the run's original timestamps. These tests cover existing behavior; they do not validate the redesigned browser contract.

## Source checks

- The installed SDK's `WKWebViewConfiguration.h` documents that a `WKURLSchemeHandler` cannot register a scheme WebKit already handles. A custom handler is therefore not an HTTP/HTTPS interception API.
- The installed SDK's `Network.swiftinterface` exposes the proxy domain lists and failover setting used above. This probe does not establish that every possible Network or WebKit configuration fails.
- [WebKit's upstream network session implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/NetworkProcess/cocoa/NetworkSessionCocoa.mm) applies data-store proxy configurations to its URL sessions.
- [WebKit's upstream WebRTC provider](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/NetworkProcess/webrtc/NetworkRTCProvider.cpp) creates separate Cocoa UDP and TCP socket implementations. Those sources explain why network paths need separate checks; they do not prove the installed framework behaves identically to upstream main.
- The repository's `docs/REMOTE_BROWSER_PROTOTYPE.md` records an earlier iPhone Simulator WebRTC bypass. No fresh WebRTC test was run here.

## Open work and product boundary

The demonstrated HTTP CONNECT configuration fails the agreed localhost routing requirement. Keep the existing protections and Mac-rendered behavior while investigating a genuine replacement.

A supported network extension or another native networking mechanism needs feasibility work, including installation/permission requirements, iOS deployment constraints, simultaneous servers with identical localhost URLs, and WebRTC. None has been validated by this probe.

Server-specific URL aliases or a custom URL scheme would change the site's origin and require separate compatibility evidence and Gordon's explicit approval before becoming a substitute. Reusing rendered streaming would also change the agreed destination. No such substitute has been built or selected.

SOCKS5, HTTPS, redirects, subresources, private DNS, WebSockets, WebRTC, stopped-proxy behavior, iPhone/iPad clients, real Rust endpoints, cookie synchronization and native transfer workflows remain untested in this new probe. Windows and Linux validation remains deferred by the map. Human review and GUI opt-in remain outstanding.
