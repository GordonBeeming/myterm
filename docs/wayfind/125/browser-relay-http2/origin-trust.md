# Scoped HTTPS origin trust through WebKit

Offscreen WebKit on macOS 27.3 routed HTTPS through two separately configured trusted HTTP/2 relays. Both relays passed encrypted bytes to the same local HTTPS origin fixture. The HTTPS certificate was untrusted in the default macOS trust store and had both fixture hostnames as subject alternative names. No certificate was installed in macOS.

| Authorization presented to the browser | Result |
| --- | --- |
| None | WebKit rejected the origin certificate |
| Exact fixture server identity, host, port and leaf certificate | Loaded the original HTTPS URL |
| Same origin and certificate over another assigned server | Rejected |
| Same certificate on the other hostname it covers | Rejected |
| Same certificate and hostname on another port | Rejected |
| Same server and destination with a different approved leaf | Rejected |

The origin trust challenge arrived in WebKit for the destination host and port. The approved route used a separate trust evaluation with the presented leaf and SSL hostname policy. It kept normal handling for every unapproved route. See [the six observations](origin-trust-results.json).

This shows that an app can scope an **origin** certificate exception after a working relay has already been authenticated. The server identifiers in this probe select separate local relay endpoints. It does not establish how production enrollment binds an authenticated server identity to a trusted relay certificate. It also leaves the user-facing approval flow, subresource and redirect coverage, and iPhone/iPad verification open.

## Repeat

Provide a publicly trusted loopback fixture certificate chain and matching key as described in the [transport comparison](transport-comparison.md). The parent relay uses that certificate. The runner generates temporary certificates for the two local HTTPS origins and starts every listener on loopback.

```sh
MYTERM_RELAY_HOST=probe.localhost.direct MYTERM_RELAY_CERT="$fixture_chain" \
  MYTERM_RELAY_KEY="$fixture_key" bash docs/wayfind/125/browser-relay-http2/run-origin-trust.sh
```
