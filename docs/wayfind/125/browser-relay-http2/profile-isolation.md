# Same-origin profiles through two WebKit relays

Two live native views opened the same URL using distinct website data stores and trusted HTTP/2 relay endpoints. Each endpoint returned its own page title. The iPhone and iPad simulators used an unchanged `localhost` URL. The Mac used a remote-only test hostname because [the trusted Mac WebKit probe bypasses the proxy for loopback](transport-comparison.md).

| Check | macOS WebKit | iPhone Simulator | iPad Simulator |
| --- | --- | --- | --- |
| Each view reached its own relay at the identical origin | Passed | Passed | Passed |
| The second store started with empty cookies and web storage | Passed | Passed | Passed |
| Writes in the second store left the first store's values in place | Passed | Passed | Passed |
| A new view in the first store kept its cookie and localStorage, with fresh sessionStorage | Passed | Passed | Passed |
| Deletion in the first store left the second store's cookie and localStorage in place | Passed | Passed | Passed |

The page title distinguishes the responding endpoint and the JavaScript snapshot verifies the actual origin, cookie, localStorage and sessionStorage. See [profile-results.json](profile-results.json). Desktop uses nonpersistent WebKit stores. The simulator uses separate persistent identifiers and discards the simulator after the test. A new view within one running process is covered. Account or device cookie synchronization and independent server deployment remain unverified.

After the runner terminated and relaunched the simulator app, the second profile still opened the identical origin through its assigned relay with `localStorage` intact. Its cookie was gone on both devices. A follow-up on iPhone set a second cookie through `WKHTTPCookieStore`, the API Companion uses to apply shared cookies. WebKit reported both cookies present and non-session-only before termination. Neither appeared in the restarted page. This was an immediate process termination and relaunch. It establishes a failure to recover these cookies under that condition. Keeping the iPhone fixture app running for 20 seconds before termination produced the same result. A normal background or quit sequence and restoration via server-managed cookie sync remain separate checks.

The existing Mac regression suite passed 30 selected tests: 16 for profile scopes and settings, five for artifact serving and grants, six for sign-in callbacks, and three for the current native proxy destination policy. The destination tests cover current address restrictions, including mixed DNS responses and numeric pinning. They do not authorize private-network access under the redesigned account policy.

## Repeat

Enable the profile test with `MYTERM_PROBE_PROFILES=1` and use HTTP/2. Set `MYTERM_PROBE_PROFILE_IDLE=20` to reproduce the delayed relaunch check. The desktop command requires a local fixture certificate that WebKit trusts. See the [certificate setup](transport-comparison.md).

```sh
MYTERM_PROBE_PROFILES=1 bash docs/wayfind/125/browser-relay-http2/run-trusted-simulator.sh
MYTERM_PROBE_PROFILES=1 bash docs/wayfind/125/browser-relay-http2/run-trusted-simulator.sh \
  com.apple.CoreSimulator.SimDeviceType.iPad-10th-generation

MYTERM_PROBE_PROFILES=1 MYTERM_RELAY_HOST=probe.localhost.direct \
  MYTERM_RELAY_CERT="$fixture_chain" MYTERM_RELAY_KEY="$fixture_key" \
  bash docs/wayfind/125/browser-relay-http2/run.sh

swift test --scratch-path "$scratch/build" --jobs 4 \
  --filter 'BrowserDataProfilesTests|NativeBrowserDestinationPolicyTests|CompanionExternalBrowserAuthenticationTests|CompanionBrowserArtifactTests.test(Artifact|FailedArtifact|NativeArtifact|BrowserRoute)'
```
