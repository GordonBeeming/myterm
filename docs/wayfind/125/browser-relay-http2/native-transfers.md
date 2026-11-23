# Native WebKit file transfers through the proxy

Offscreen macOS WebKit uploaded and downloaded the same generated 8 MiB file through a trusted HTTP/2 proxy and the scoped HTTPS origin exception. The origin measured the upload independently. Its byte count and SHA-256 digest matched the client fixture, as did the saved download.

| Case | Result |
| --- | --- |
| Select upload | WebKit called the native open-panel delegate and the origin received all 8 MiB. |
| Cancel selection | The delegate returned no file. The page received no upload result and the origin saw no upload for that case. |
| Origin rejects upload | The origin received the expected file and the page reported HTTP 422. |
| Complete download | WebKit's download delegate returned the suggested filename and recorded completion. The probe moved the verified file into its final scratch path. |
| Cancel in progress | The probe waited for partial progress, called the native cancel API, and received its completion callback. The origin saw its stream close. No final file was published. |
| Broken download | The origin closed the response after 32 KiB. WebKit reported a network error, and the probe removed the partial file without publishing it. |

The native delegate supplied the upload selection and download destination programmatically. This verifies native callbacks and transport. It leaves the visible picker, save and share UI and production Rust server integration unverified. The existing six HTTPS trust cases also passed against the expanded fixture.

[Measurements](transfer-results.json) include the file digest, callbacks, and error codes. WebKit reports navigation code 102 when the navigation converts into a download. Its separate download delegate supplied the actual transfer outcome.

## Mobile comparison

The iPhone and iPad simulators also uploaded all 8 MiB with the matching digest and exercised selection cancellation and HTTP 422. The iPad upload-cancellation page failed to load in one concurrent run and passed in an isolated rerun. Both passed the 8 MiB download, cancellation, and truncated-response cases when the web view started an explicit `WKDownload` and its delegate applied the same origin-certificate policy. This covers an explicit GET download. It does not verify automatic downloads or replay of POST requests and form bodies.

In the iPhone attachment-response conversion test, navigation failed with `-1005` before the download delegate received a trust challenge. The same scoped trust callback worked on the explicit download path. The production browser must preserve the original request and trust semantics for both user-initiated and response-initiated downloads. [Mobile results](mobile-transfer-results.json)

## Repeat

Use the same trusted development certificate setup as the [origin trust fixture](origin-trust.md).

```sh
MYTERM_PROBE_TRANSFERS=1 MYTERM_RELAY_HOST=probe.localhost.direct \
  MYTERM_RELAY_CERT="$fixture_chain" MYTERM_RELAY_KEY="$fixture_key" \
  bash docs/wayfind/125/browser-relay-http2/run-origin-trust.sh
```

For mobile, run the simulator command in [native navigation](native-navigation.md). Omit `MYTERM_WORKFLOW_DIRECT_DOWNLOAD=1` to reproduce the attachment-response conversion path.
