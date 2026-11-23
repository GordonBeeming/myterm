# Scoped HTML artifacts through native WebKit

The offscreen Mac probe compiles MyTerm's existing `CompanionBrowserArtifact.swift` directly. Two loopback instances of that server each opened a generated HTML file, granting its containing directory. Each WebKit store routed the same virtual origin through a distinct trusted HTTP/2 relay to its assigned fixture server.

| Check | Result |
| --- | --- |
| Assigned artifact and relative stylesheet | Both pages returned 200 with their own titles and the expected CSS color. |
| Local-file JavaScript | The first grant blocked the inline script. The second, which allowed JavaScript, ran it. |
| Files outside the grant | A missing in-grant path and a symbolic link to the generated file outside the grant both returned 404. |
| Writes | POST returned 405. |
| Unregistered virtual origin | The artifact server returned 403. |
| Grant revocation | Closing the first artifact listener caused the next uncached navigation to fail. The other grant still returned its own page at the same origin. |

The locally generated fixtures use separate data stores. The test checks the existing Swift grant implementation and a Mac proxy route. It does not cover creating or approving a remote grant from the client, artifacts on the redesigned Rust server, mobile rendering, or resuming a grant after the server reconnects. It also does not establish a new origin allocation policy. A stable virtual origin within a grant should remain tied to the server and grant identity so a replacement grant cannot inherit unrelated website data.

See [results](artifact-results.json). The revoked load may leave the previous title visible in WebKit. The recorded navigation error and absence of a completed response establish revocation on the wire, not a UI clearing policy.

## Repeat

Use the normal-trust loopback development certificate setup described in the [transport comparison](transport-comparison.md). The runner creates its files in a separate scratch directory and opens no windows.

```sh
MYTERM_RELAY_HOST=probe.localhost.direct MYTERM_RELAY_CERT="$fixture_chain" \
  MYTERM_RELAY_KEY="$fixture_key" bash docs/wayfind/125/browser-relay-http2/run-artifact.sh
```
