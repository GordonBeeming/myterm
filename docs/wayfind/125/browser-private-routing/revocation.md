# Live revocation of a native browser proxy stream

The Linux Rust fixture admits two native WebKit views to the same private origin using separate synthetic admission values. Each view starts a streaming fetch over its proxy connection. The harness waits for both views to receive bytes before the proxy commits revocation for one value. Rust resets the revoked view's active HTTP/2 tunnel and refuses its next CONNECT.

The revoked view reports an interrupted fetch and cannot make a fresh request using the same admission value. The unrevoked control keeps receiving bytes after the policy commit and can make a new request. This tests the live proxy boundary, including an existing tunnel, while the origin and the other browser stay online. The recorded byte counts may include data already buffered before the reset. A revocation cannot retract bytes already received.

Mac and both mobile simulators passed over the private IPv4 route. Both mobile simulators also passed over the private DNS route after the forwarding change. [Five native runs and the routing regression](revocation-results.json)

## HTTP/2 forwarding regression

The previous forwarder always waited for a capacity notification before sending, even when the stream already held usable send credit. The controlled in-memory HTTP/2 test timed out on the old code and passed after the forwarder started checking existing credit before waiting. The original Mac private DNS and IPv4 routing checks still passed after the fix. The initial mobile hostname revocation probes had timed out before reaching the revocation phase. The flow-control test proves the fixture stall. It does not, by itself, identify the cause of every earlier browser timeout.

## Boundary

The browser views and stream resets are real. A fixture file triggers revocation and no production enrollment or account service runs. Propagating authenticated policy across servers, replay and expiry, untrusted intermediate operators and real-device reliability remain separate checks. Any traffic outside the proxy, including the independently observed WebRTC bypass, is outside this fixture's enforcement.

## Repeat

Use the [private routing setup](README.md) and set `MYTERM_PRIVATE_CHECK_REVOCATION=1`. The default target is the private IPv4 address. Set `MYTERM_PRIVATE_REVOCATION_TARGET=private-name` to test the assigned server's private DNS route. Use `MYTERM_PRIVATE_SIMULATOR_TYPE` as in the routing setup to select a disposable iPhone or iPad simulator.

```sh
cargo test --locked --manifest-path docs/wayfind/125/browser-private-routing/Cargo.toml
```
