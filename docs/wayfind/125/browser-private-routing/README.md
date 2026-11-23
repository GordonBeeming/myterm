# Private destinations through a Linux Rust proxy

Native WebKit on Mac, iPhone Simulator and iPad Simulator loaded a private DNS name and a private IPv4 address through a native Linux ARM64 Rust HTTP/2 proxy. The Linux origin only served requests from the proxy container's address. A direct request from another container received HTTP 403. The Mac resolver had no answer for the private name. The Rust proxy resolved it through the Linux bridge's DNS and connected to the designated address.

| Scenario | Result |
| --- | --- |
| Private DNS name | Loaded through Rust on Mac and both mobile simulators. |
| Private IPv4 number outside loopback | Loaded through Rust on Mac and both mobile simulators. |
| Host outside the fixture allowlist | Blocked before reaching the origin. |
| Proxy stopped while the origin remained live | A fresh Mac WebKit process failed to connect to either private destination. |
| Direct connection from a different Linux source | The origin returned 403. |

The two containers execute native ARM64 Linux binaries in an OrbStack VM. Only the TLS proxy port is published on Mac loopback. The native browser uses normal proxy TLS verification with a publicly trusted development certificate. These are test containers and a source-restricted fixture, while the product still needs approval-bound routing with arbitrary authorized destinations. The result does not establish a production Rust server installation, Windows or real-device coverage, Apple loopback behavior, WebRTC containment or the production approval protocol. The origin permit is an address check in the fixture.

See [the two runs](route-results.json) for native navigation outcomes and the proxy's DNS and source observations. The original [loopback mismatch](../browser-relay-http2/transport-comparison.md) is separate. The successful numeric IPv4 result here used an address outside loopback.

The [native admission follow-up](admission.md) checks scoped fixture header delivery, rejects missing and wrong admission values, and observes a raw forwarding hop without a TLS key.

The [live revocation follow-up](revocation.md) verifies that Rust can reset an established stream and refuse its next request while another native view keeps receiving data.

## Repeat

The script expects a local OrbStack Docker engine, Xcode and a Rust fixture registry cache. Use the local development certificate setup in [trusted transport comparison](../browser-relay-http2/transport-comparison.md). The private network, Docker port, and simulator are disposable. Set a different unused RFC 1918 subnet prefix with `MYTERM_PRIVATE_SUBNET_PREFIX` if the default three-octet prefix is in use.

```sh
cargo fetch --locked --manifest-path docs/wayfind/125/browser-private-routing/Cargo.toml

MYTERM_RELAY_HOST=probe.localhost.direct MYTERM_RELAY_CERT="$fixture_chain" \
  MYTERM_RELAY_KEY="$fixture_key" MYTERM_RUST_REGISTRY="${CARGO_HOME:-$HOME/.cargo}/registry" \
  MYTERM_PRIVATE_SIMULATOR_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-11 \
  bash docs/wayfind/125/browser-private-routing/run.sh
```

For iPad set `MYTERM_PRIVATE_SIMULATOR_TYPE=com.apple.CoreSimulator.SimDeviceType.iPad-10th-generation`. Omit the simulator setting for Mac only. [OrbStack headless operation](https://docs.orbstack.dev/headless)
