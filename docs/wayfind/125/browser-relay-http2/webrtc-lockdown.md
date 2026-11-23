# WebRTC containment with public WebKit settings

The proxy browser sets the public per-view `WKWebpagePreferences.isLockdownModeEnabled` preference before loading a synthetic page over a trusted HTTP/3 relay. The test checks the WebRTC data-channel API and listens on a disposable client-local UDP port for STUN. It requests no microphone or camera access. The runner also stops the relay while the same protected WebKit document stays loaded and repeats the top-level and embedded-frame checks. [Apple per-view Lockdown preference](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/islockdownmodeenabled)

| Check | Mac | iPhone Simulator | iPad Simulator |
| --- | --- | --- | --- |
| Proxied page loaded before the outage | Passed | Passed | Passed |
| Top-level WebRTC API under Lockdown | Absent, zero STUN | Absent, zero STUN | Absent, zero STUN |
| Embedded frame WebRTC API under Lockdown | Absent, zero STUN | Absent, zero STUN | Absent, zero STUN |
| Same page and frame after stopping the relay | API absent, zero STUN | API absent, zero STUN | API absent, zero STUN |

The ordinary Mac control emitted five client-local STUN datagrams. The Mac maximize-compatibility mode also emitted five on a relayed page. On the mobile harness the unrestricted view exposed the WebRTC API, while the observer did not see STUN in that particular control. The earlier [Companion simulator positive control](companion-baseline.md) observed device-local STUN. The mobile result here rests on API removal before and after stopping the relay, rather than an inference from a silent observer alone.

WebKit's Cocoa source applies the view's custom proxy configs to URL-session networking. The RTC UDP code builds a separate Network.framework socket. This separation is consistent with the measured bypass in ordinary mode. The inspected source does not establish how every WebKit port handles RTC. [URL-session proxy application](https://github.com/WebKit/WebKit/blob/fb7300f9ff38f0b603726a4324752002732e93e2/Source/WebKit/NetworkProcess/cocoa/NetworkSessionCocoa.mm#L2143-L2153) · [WebKit Cocoa RTC UDP socket](https://github.com/WebKit/WebKit/blob/fb7300f9ff38f0b603726a4324752002732e93e2/Source/WebKit/NetworkProcess/webrtc/NetworkRTCUDPSocketCocoa.mm#L387-L413) · [Apple maximize-compatibility setting](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/securityrestrictionmode)

## Compatibility

The Mac and iPhone Simulator Lockdown workflows passed the HTTPS login redirect, popup, CORS, WebSocket reconnection and native 8 MiB transfer cases. Both ordinary controls completed an IndexedDB write/read. Lockdown removed IndexedDB and FileReader on both platforms. It also removed Service Worker exposure on the Mac, where the ordinary control exposed it. This is a difference in what a site can do inside one view, independently of any decision about cross-device storage synchronization.

The public setting therefore demonstrates a way to disable WebRTC without system configuration. It also disables application APIs that the browser must preserve for some existing workflows. The results require a compatibility decision before Lockdown could be the general proxy-browser mode. Neither setting resolves the [exact-loopback routing conflict](https://github.com/GordonBeeming/myterm/issues/207). The Mac Lockdown fixture retained the direct loopback behavior with the proxy both up and stopped.

[Recorded native runs and controls](webrtc-lockdown-results.json) include the storage round trip and transfer hashes. The [closure audit](closure-audit.md) maps the remaining requirements to evidence and decision gates.

## Repeat

Use the trusted certificate setup in [transport comparison](transport-comparison.md) for the Mac commands. The mobile fixture installs its trust root only inside a disposable simulator.

```sh
MYTERM_PROBE_TRANSPORT=http3 MYTERM_PROBE_WEBRTC=1 MYTERM_PROBE_LOCKDOWN=1 \
  MYTERM_PROBE_WEBRTC_OUTAGE=1 bash docs/wayfind/125/browser-relay-http2/run.sh

MYTERM_PROBE_TRANSPORT=http3 MYTERM_PROBE_WEBRTC=1 MYTERM_PROBE_LOCKDOWN=1 \
  MYTERM_PROBE_WEBRTC_OUTAGE=1 bash docs/wayfind/125/browser-relay-http2/run-trusted-simulator.sh

MYTERM_PROBE_TRANSPORT=http3 MYTERM_PROBE_WEBRTC=1 MYTERM_PROBE_MAX_COMPAT=1 \
  bash docs/wayfind/125/browser-relay-http2/run.sh

MYTERM_PROBE_NAVIGATION=1 MYTERM_PROBE_LOCKDOWN=1 \
  bash docs/wayfind/125/browser-relay-http2/run-origin-trust.sh

MYTERM_PROBE_TRANSFERS=1 MYTERM_PROBE_LOCKDOWN=1 \
  bash docs/wayfind/125/browser-relay-http2/run-origin-trust.sh

MYTERM_WORKFLOW_DIRECT_DOWNLOAD=1 MYTERM_PROBE_LOCKDOWN=1 \
  bash docs/wayfind/125/browser-relay-http2/run-workflows-simulator.sh
```
