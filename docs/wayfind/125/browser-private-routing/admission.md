# Native proxy admission and TLS forwarding

The native WebKit fixture supplies a generated admission value using Network.framework's additional HTTP header fields on an HTTP/2 relay hop. A Rust proxy on Linux checks that value on CONNECT before resolving the destination. The nested browser request remains unchanged. The origin checks that it received no admission header and serves only the Rust proxy's source address. [Apple relay headers](https://developer.apple.com/documentation/network/proxyconfiguration/relayhop/init%28http2relayendpoint%3Atlsoptions%3Aadditionalhttpheaderfields%3A%29)

Mac, iPhone Simulator and iPad Simulator passed the admission cases in isolated runs. An earlier iPhone attempt received HTTP 200 for the permitted private hostname but timed out before completing navigation. Its other controls passed. The repeat establishes feasibility without resolving that intermittent failure.

| Native request | Observed fixture outcome |
| --- | --- |
| Valid value and private DNS name | Assigned origin returns its page. |
| Valid value and private IPv4 address | Assigned origin returns its page. |
| Valid value and a hostname outside the fixture list | Rust denies CONNECT. |
| Missing or wrong value for an allowed address | Rust denies CONNECT before dialing the origin. |
| Proxy stopped | Mac reports a connection error without loading the origin. |

A raw Mac TCP forwarder sits between WebKit and the TLS-terminating Rust process. The forwarder receives no TLS key and handles both directions as bytes. Its successful connection records contain traffic in both directions and neither the admission value nor the origin page marker. A separate Rust test verifies that its marker detector handles a marker divided across read boundaries. This is a check of the fixture's forwarding topology and TLS termination point. Production enrollment, cryptographic server binding, expiry, replay protection, and approval revocation still need implementation and integration tests.

See [native results and fixture observations](admission-results.json). To repeat, use the [private routing setup](README.md) and add `MYTERM_PRIVATE_CHECK_ADMISSION=1`.
