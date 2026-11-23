# Trusted HTTP/2 relay in iOS Simulator

The iPhone 11 and iPad (10th generation) simulators on iOS 27.0 (24A5408d) both loaded the relay's page at the original `http://localhost:<port>/routing-probe` URL. The relay logged HTTP/2 CONNECT for `localhost:<port>` and the enclosed HTTP GET. The same WebKit configuration also loaded the remote-only hostname through the relay. The client-local listener received zero HTTP requests in both cases.

| Target | Relay running | Relay stopped |
| --- | --- | --- |
| Remote-only hostname | Loaded relay fixture page | Connection refused |
| `localhost` | Loaded relay fixture page | Connection refused |
| `127.0.0.1` and `[::1]` | Connection lost before CONNECT | Connection lost |

The client-local listener received zero HTTP requests across all 16 navigations in the final runs. An earlier run on both simulators reached CONNECT for `localhost` but failed to display the fixture page until the relay explicitly flushed its response and kept the stream open briefly. The [recorded results](trusted-simulator-results.json) include the relay request logs and the normal-hostname control.

The runner creates a new simulator, installs a short-lived test root inside it, and deletes the simulator afterward. A local TLS listener presents a leaf signed by that root. WebKit uses default trust checks with failover disabled. The probe does not alter macOS trust or use a VPN. This fixture does not establish how shipping clients will trust the relay without extra setup.

The relay serves a recognizable fixture response after CONNECT. This verifies WebKit's destination choice, page delivery and behavior with the relay stopped. It does not exercise a Rust server, MyTerm's encrypted tunnel, a separate physical host or WebRTC containment.

## Repeat

Run on an Apple silicon Mac with the corresponding iOS Simulator runtime, Xcode, Go and jq.

```sh
bash docs/wayfind/125/browser-relay-http2/run-trusted-simulator.sh
bash docs/wayfind/125/browser-relay-http2/run-trusted-simulator.sh \
  com.apple.CoreSimulator.SimDeviceType.iPad-10th-generation
```
