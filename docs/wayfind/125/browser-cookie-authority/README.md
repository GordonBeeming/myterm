# Assigned-server browser cookie authority

The account trust decision lets approved clients communicate with an assigned server through an authenticated, end-to-end encrypted channel. A Rust server can own the durable cookie state for an account, server and browser profile without running WebKit or depending on a Mac client. Each client still uses its own WebKit data store. The browser synchronization channel would carry cookie changes and deletion records only after the server checks the client and current workspace policy. Private keys and cookie values stay unavailable to the hosted relay. [Account trust decision](https://github.com/GordonBeeming/myterm/issues/129#issuecomment-6701343151) · [Channel integration follow-up](https://github.com/GordonBeeming/myterm/issues/178)

The candidate gives each cookie key a server version. A client sends the version from its last view of the cookie with each mutation. The server can merge changes to independent cookies. If a change conflicts with an accepted mutation, the client refreshes its snapshot instead of overwriting the accepted value. A deletion keeps its version so an offline client cannot recreate a signed-out session with an old write.

Any workspace opt-out disables export and mutation for the entire shared profile. An effective sharing-policy change advances a generation so queued writes based on the old policy fail after sharing is re-enabled. The network implementation still needs to stop subscriptions and revalidate the current policy before sending queued responses. How the user wants stored cookies handled when sharing is re-enabled remains open.

The Rust fixture persists an authenticated encrypted snapshot under a local fixture key. It binds the ciphertext to the account, server and profile. It commits state before exposing it to another client and distinguishes an explicit new profile from missing or damaged state. The test key and all values are synthetic. The fixture does not implement endpoint enrollment, a network protocol, key provisioning, expired-cookie policy, or distributed storage. Power-loss durability is outside this run. Changes to WebKit localStorage, IndexedDB and sessionStorage remain local in this proposal. [AEAD library](https://github.com/RustCrypto/AEADs/tree/master/chacha20poly1305)

## Evidence

Seven Rust tests passed on macOS. They check bidirectional publication to two modeled approved clients, restart recovery, stale sign-out replay, independent changes, atomic conflict rejection, profile-wide opt-out, copied ciphertext and scope isolation, failed storage commits and missing state. The probe receives already-approved scopes from the test harness, so the tests do not prove authentication or revocation on a live channel.

Existing implementations also passed the targeted cookie regressions. The Mac run passed 16 browser profile tests, one native WebKit jar isolation test and 17 cookie protocol tests. The iPhone Simulator passed all eight Companion cookie reconciliation tests. These suites exercise the current Mac-based sync model and wire validation. They are separate from the Rust state model.

The [native WebKit restore follow-up](webkit-restore.md) transfers one generated cookie through the Rust state fixture and verifies the assigned HTTP request after relaunch on both mobile simulators.

## Repeat

```sh
TMPDIR=/private/tmp CARGO_TARGET_DIR=/private/tmp/myterm-cookie-authority-target \
  cargo test --locked --manifest-path docs/wayfind/125/browser-cookie-authority/Cargo.toml

swift test --scratch-path "$scratch/build" --jobs 4 \
  --filter 'BrowserCookieProtocolTests|BrowserDataProfilesTests|BrowserSessionControllerTests.testNamedStoresShareCookiesOnlyWithTheSameIdentifier'

xcodebuild test -project Companion/MyTermCompanion.xcodeproj -scheme MyTermCompanion \
  -destination "platform=iOS Simulator,id=$disposable_simulator" \
  -derivedDataPath "$scratch/companion-build" -resultBundlePath "$scratch/cookie-tests.xcresult" \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:MyTermCompanionTests/BrowserCookieReconcilerTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-
```
