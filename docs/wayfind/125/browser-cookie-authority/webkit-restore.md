# Restore a cookie before native WebKit navigates

The iPhone and iPad simulator runner captures the generated cookie from the second server's browser profile, passes it to a separate Rust process, and writes it to that authority's encrypted file. That process exits. The runner then terminates and relaunches the native app, first without the cookie, then after a second Rust process reads the snapshot for the same profile.

On each restored launch the native app applies the cookie through `WKHTTPCookieStore` before constructing the page request. The assigned fixture returns a marker only when it sees the expected cookie in the request. This distinguishes a cookie that actually traveled with navigation from a cookie that appears only when the test inspects WebKit's jar later.

| Check | iPhone Simulator | iPad Simulator |
| --- | --- | --- |
| Plain relaunch kept the assigned origin and localStorage | Passed | Passed |
| Plain relaunch sent the original cookie | Absent | Absent |
| Rust snapshot restored the cookie into WebKit | Passed | Passed |
| Assigned fixture observed the cookie on the first restored request | Passed | Passed |

See [the recorded controls and restored requests](webkit-restore-results.json). The shell transfers one generated cookie value between the model and simulator. This test does not prove the authenticated production channel, generalized cookie serialization, expiry policy or relay confidentiality. The same-process proxy and assigned-origin simulator fixture can inspect the generated HTTP request to emit its marker.

## Repeat

```sh
CARGO_TARGET_DIR=/private/tmp/myterm-cookie-authority-target \
  cargo build --locked --manifest-path docs/wayfind/125/browser-cookie-authority/Cargo.toml \
  --bin cookie-fixture

MYTERM_PROBE_PROFILES=1 \
  MYTERM_PROBE_COOKIE_FIXTURE=/private/tmp/myterm-cookie-authority-target/debug/cookie-fixture \
  bash docs/wayfind/125/browser-relay-http2/run-trusted-simulator.sh

MYTERM_PROBE_PROFILES=1 \
  MYTERM_PROBE_COOKIE_FIXTURE=/private/tmp/myterm-cookie-authority-target/debug/cookie-fixture \
  bash docs/wayfind/125/browser-relay-http2/run-trusted-simulator.sh \
  com.apple.CoreSimulator.SimDeviceType.iPad-10th-generation
```
