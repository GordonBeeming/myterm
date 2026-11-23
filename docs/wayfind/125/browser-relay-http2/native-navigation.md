# Native login, popups, WebSockets and proxy recovery

The navigation fixture runs in client-rendered WebKit over a trusted HTTP/2 relay. It uses two HTTPS origins, each with an explicitly scoped exception for the disposable origin certificate. Mac WebKit and iPhone and iPad simulators completed the workflow. The origin and relay logs show the redirect, cross-origin requests and WebSocket traffic. Separate concurrent simulator runs intermittently lost the connection on back navigation with error -1005. The successful controls establish feasibility for these fixtures. They leave that reliability gap open.

| Scenario | Observed result |
| --- | --- |
| Login redirect | The app origin redirected to the identity-provider origin, then returned to the original host. The callback set a secure HTTP-only cookie and the origin's login check returned 200. |
| Independent view | A second view started from the same URL. Signing in and navigating the first view left the second on its starting page, without a back entry. Its login check stayed at 401. |
| Cross-origin fetch | The page could read the response with the correct CORS header. WebKit denied access to the response without that header. |
| Native popup | The native delegate created a child view using the opener's website data store. The popup posted a message from the expected origin and closed. The opener stayed on the signed-in page. |
| Back and forward | The first view went back to the shared starting URL and forward to its signed-in URL. |
| Hot reload | Two secure WebSocket connections each delivered a distinct event and the origin logged the client's acknowledgment before closing the connection. |

The outage fixture on Mac exercised the same live view before, during, and after a relay process restart. The target hostname resolves to the client-side listener, but the relay forwards to a different origin port. With the relay stopped, the view returned `NSURLErrorCannotConnectToHost` and the decoy accepted no TCP connection. The reloaded page succeeded after the relay returned on the same port. The direct positive control then reached the observer. Only the initial and recovered requests appeared at the assigned origin. See [results](navigation-results.json).

The fixtures cover native WebKit delegate behavior and proxy transport for the named origins. They leave real third-party identity-provider flows, production Rust endpoints and WebRTC containment unverified. The process restart test uses a single Mac browser view and a separate relay process. It does not demonstrate mobile path recovery.

## Repeat

The Mac commands use the same trusted development certificate as the [origin trust fixture](origin-trust.md). The simulator runner creates and removes its own device and trusts only its temporary test root there.

```sh
MYTERM_PROBE_NAVIGATION=1 MYTERM_RELAY_HOST=probe.localhost.direct \
  MYTERM_RELAY_CERT="$fixture_chain" MYTERM_RELAY_KEY="$fixture_key" \
  bash docs/wayfind/125/browser-relay-http2/run-origin-trust.sh

MYTERM_PROBE_OUTAGE=1 MYTERM_RELAY_HOST=probe.localhost.direct \
  MYTERM_RELAY_CERT="$fixture_chain" MYTERM_RELAY_KEY="$fixture_key" \
  bash docs/wayfind/125/browser-relay-http2/run-origin-trust.sh

MYTERM_WORKFLOW_DIRECT_DOWNLOAD=1 \
  bash docs/wayfind/125/browser-relay-http2/run-workflows-simulator.sh

MYTERM_WORKFLOW_DIRECT_DOWNLOAD=1 \
  bash docs/wayfind/125/browser-relay-http2/run-workflows-simulator.sh \
  com.apple.CoreSimulator.SimDeviceType.iPad-10th-generation
```
