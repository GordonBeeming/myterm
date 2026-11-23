# WebKit loopback routing with an HTTP/2 relay

WebKit sent literal loopback requests to the client with a per-web-view HTTP/2 relay configured and failover disabled. Both runs returned the client fixture page for `localhost`, `127.0.0.1`, and `[::1]`, including after the relay was stopped. The non-loopback control failed earlier in the connection, so a working tunnel with a trusted relay certificate remains untested.

| Target | Relay listening | Relay stopped |
| --- | --- | --- |
| Remote-only hostname | Relay TLS validation failed (`-1202`). No client-origin requests. | Connection refused (`-1004`). No client-origin requests. |
| `localhost`, `127.0.0.1`, `[::1]` | One direct client-origin GET per target. | One direct client-origin GET per target. |

The loopback-only Go fixture generates its own certificate in memory and writes the public certificate for the probe to pin. WebKit reported a certificate error for the remote-only control, and neither verification callback logged a call. WebKit stopped at TLS, before sending CONNECT. The probe leaves system trust and network settings alone. Before loading WebKit, the runner uses a Go client to trust that same certificate in process. The control completed HTTP/2 CONNECT, carried an HTTP/1.1 GET and returned the fixture page.

The [earlier HTTP CONNECT probe](https://github.com/GordonBeeming/myterm/issues/160#issuecomment-6875187932) reached its proxy for the remote-only control and reproduced the same direct loopback route. Keep Companion's loopback block until a replacement can prove that all supported routes reach the assigned server and fail closed. A follow-up HTTP/2 or HTTP/3 experiment needs a trusted relay and a successful non-loopback control before testing native parity.

## Repeat

Run on a Mac with Go, Xcode and jq available. The runner uses two disposable local listeners, prints JSON to stdout and leaves the scratch path on stderr with the relay log. It opens no windows. The tool sandbox denied offscreen WebKit access to helper services, so the recorded run used host access.

```sh
bash docs/wayfind/125/browser-relay-http2/run.sh
```

Recorded on macOS 27.3 (26C5047e), Xcode 27.2 (27B52), and Go 1.26.6 on arm64. See [results.json](results.json). The experiment only tests desktop WebKit routing. It does not exercise MyTerm's encrypted tunnel, a Rust server, HTTP/3, iPhone or iPad.
