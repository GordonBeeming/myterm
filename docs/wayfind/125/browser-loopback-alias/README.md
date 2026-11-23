# Opt-in loopback alias with native WebKit

The synthetic configured hostname `app.dev.myterm.test` uses HTTPS port 443 in the browser. The native Linux Rust proxy maps that authority to `127.0.0.1:3000` in its own network namespace. The HTTPS origin listens only on that loopback address. The runner publishes just the TLS proxy port, on Mac loopback, and uses a development certificate for the proxy. The origin's generated certificate is accepted only for the exact alias and pinned leaf.

The WebKit fixture enables per-view Lockdown, disables proxy failover, and uses three checks for literal loopback. It rejects app-initiated literal addresses before calling WebKit, cancels page-initiated literal navigation in the navigation delegate, and blocks matching subresource URLs with a content rule list. Separate kernel-bound client-local IPv4 and IPv6 listeners count connections and are tested with a direct positive control for each family.

The Mac baseline with content rules alone rejected the attempted loads but still opened three client-local TCP connections. With the navigation checks in place, the tested literal routes and loopback fetches produced zero client-local connections. This establishes why an HTTP-level error alone is insufficient evidence that traffic stayed off the client network.

The positive alias route checks the scoped certificate exception, normal rejection without that exception, a login redirect, a secure cookie accepted by the assigned origin, relative CSS, localStorage, and the absence of WebRTC in both the loaded page and its embedded frame. A request for an unconfigured hostname fails. The probe covers the chosen alias, the tested literal forms and the recorded client environments. Broader URL canonicalization, production Companion wiring, real-device testing and the full browser workflow acceptance matrix remain separate requirements.

The final Mac, iPhone Simulator, and iPad Simulator runs passed the same checks. Every run confirmed both loopback observers with separate direct controls and then measured zero connections from the guarded browser. See [observations](alias-results.json).

## Repeat

Use the development certificate and offline Rust cache from the [private routing fixture](../browser-private-routing/README.md). OrbStack must be running. The script creates and removes its own containers and optional simulator.

```sh
MYTERM_RELAY_HOST=probe.localhost.direct MYTERM_RELAY_CERT="$fixture_chain" \
  MYTERM_RELAY_KEY="$fixture_key" MYTERM_RUST_REGISTRY="$cargo_registry" \
  bash docs/wayfind/125/browser-loopback-alias/run.sh
```

Set `MYTERM_ALIAS_SIMULATOR=com.apple.CoreSimulator.SimDeviceType.iPhone-11` or `com.apple.CoreSimulator.SimDeviceType.iPad-10th-generation` for the mobile fixture.
