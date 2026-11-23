# Trusted WebKit relay transport comparison

The macOS probe used the development certificate published by localhost.direct and bound the relay to loopback. The DNS name resolved to 127.0.0.1. The fixture used WebKit's standard certificate validation without changing the Mac's trust settings. The key and certificate bundle stayed outside the worktree. This is a test of platform behavior and supplies no production trust model. [localhost.direct certificate bundle](https://github.com/Upinel/localhost.direct#b-public-ca-certificate-%EF%B8%8F-may-be-revoked)

The iPhone Simulator used the temporary test root from the [simulator runner](trusted-simulator.md). The simulator was deleted afterward.

| Platform and transport | Remote-only hostname | Literal `localhost` | `127.0.0.1` and `[::1]` |
| --- | --- | --- | --- |
| macOS 27.3, HTTP/2 with default domain matching | Relay page | Client-local page | Client-local page |
| macOS 27.3, HTTP/3 with explicit domain matching | Relay page | Client-local page | Client-local page |
| iOS 27.0 Simulator, HTTP/2 with default domain matching | Relay page | Relay page | Failed before CONNECT |
| iOS 27.0 Simulator, HTTP/3 with default domain matching | Relay page | Relay page | Failed before CONNECT |

Stopping either relay produced a connection error for the remote-only hostname. On macOS, all three loopback targets still loaded the client-local page. On iOS, `localhost` failed when the relay stopped. The mobile runner observed zero client-origin HTTP requests in all configurations.

Switching protocols does not make this a complete exact-origin solution. On macOS, a working trusted relay does not override loopback bypass for any of the three tested forms. On iOS, the numeric URLs fail with an underlying POSIX `ENODATA` before the relay receives a CONNECT. Default domain matching does not change that behavior from the [previous explicit matching run](trusted-simulator.md).

## WebRTC

The macOS WebKit page loaded through the trusted HTTP/3 relay with datagrams advertised. A WebRTC data channel still sent five STUN binding requests to the client-local observer. An unproxied control produced the same five packets. The relay received no CONNECT-UDP. This establishes a bypass for this configuration with no media access requested.

On the iPhone Simulator, the HTTP/2 and HTTP/3 pages requested ICE gathering and the observer saw zero STUN datagrams. The unproxied control also produced zero, so those runs cannot establish containment. The separate [Companion baseline](companion-baseline.md) has a positive direct-traffic observation under the existing proxy. Stopping the relay prevented the relayed test page from opening. Cached pages, embedded frames and a proven containment mechanism remain open in [Prevent WebRTC traffic from bypassing the native browser proxy](https://github.com/GordonBeeming/myterm/issues/206).

See [raw JSON](transport-comparison-results.json) for each navigation and observer count.

## Repeat

For the simulator, the runner manages certificate generation and trust inside the disposable simulator.

```sh
MYTERM_PROBE_DOMAINS=default bash docs/wayfind/125/browser-relay-http2/run-trusted-simulator.sh
MYTERM_PROBE_DOMAINS=default MYTERM_PROBE_TRANSPORT=http3 \
  bash docs/wayfind/125/browser-relay-http2/run-trusted-simulator.sh
```

Add `MYTERM_PROBE_WEBRTC=1` to collect the STUN diagnostic and its unproxied control.

For desktop, supply the local paths to a development certificate chain and matching fixture key. The relay host must resolve to loopback and match the certificate. The command defaults to HTTP/2. Set `MYTERM_PROBE_TRANSPORT=http3` to compare HTTP/3, or `MYTERM_PROBE_DOMAINS=default` to leave WebKit's domain list untouched.

```sh
MYTERM_RELAY_HOST=probe.localhost.direct MYTERM_RELAY_CERT="$fixture_chain" \
  MYTERM_RELAY_KEY="$fixture_key" bash docs/wayfind/125/browser-relay-http2/run.sh
```
