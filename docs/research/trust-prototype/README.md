# Account-trust protocol research archive

This archive retains disposable trust-protocol experiments and their evidence. It is research code, with no production integration.

The approval probe asks whether a native Swift new client and a Rust approver can run BoringSSL's SPAKE2 exchange with explicit key confirmation and reject changes to the bound account, request, role and public-key fields. Both callers use the same C implementation. This demonstrates FFI interoperability on the measured Mac; it does not establish interoperability between independent SPAKE2 implementations or validate MyTerm's complete trust protocol.

The dependency is BoringSSL commit `0131ae9d78e42fcc2c1811315e62410ad96d8230`. Its archive SHA-256 is `893e755fe720627769d7bd49d15815e86cc0fd4a4ae84b3717caf6fce4255bb4`. The [public API](https://boringssl.googlesource.com/boringssl/+/0131ae9d78e42fcc2c1811315e62410ad96d8230/include/openssl/curve25519.h) describes the draft-02 variant and requires callers to perform key confirmation. This is not RFC 9382 interoperability. The probe's role-specific HMAC confirmation is application composition awaiting review. No cryptographic audit is claimed.

## Run on macOS

Requires Python 3.12+, curl, CMake, C/C++ build tools, Swift and Rust. Use disposable directories outside the repository for dependencies and output. These commands download a pinned source archive over verified HTTPS. Every harness run verifies its digest, extracts a fresh owned source tree and builds that exact dependency before compiling the callers. A digest mismatch stops the run, including if the host regenerates its archive differently.

```sh
mkdir -p /private/tmp/myterm-trust-prototype-deps
curl --fail --location --silent --show-error \
  https://codeload.github.com/google/boringssl/tar.gz/0131ae9d78e42fcc2c1811315e62410ad96d8230 \
  --output /private/tmp/myterm-trust-prototype-deps/boringssl.tar.gz
python3 docs/research/trust-prototype/run.py \
  --deps /private/tmp/myterm-trust-prototype-deps \
  --output /private/tmp/myterm-trust-prototype-results
```

`results.json` records the environment and each verdict. Codes and PAKE-derived keys remain in memory and process pipes. Eight-digit codes and random public-key fields are disposable fixtures; their format is not a product decision. Host-language string copies are not securely erased by this prototype. Production secret storage and memory handling remain unimplemented.

The same command also builds and runs `revocation-order.swift`, which uses the pinned BoringSSL Ed25519 signer and verifies its signatures with native CryptoKit. `revocation-order-results.json` records the public payloads, signatures and checks; private identity keys remain disposable in-memory fixtures. This counterexample starts from a fixture representing already verified A/B membership. It does not implement account genesis, admission or a complete membership state machine.

## Signed removal ordering

The counterexample compares genuine concurrent removals with a later removal fabricated by a removed endpoint that retains its signing key. Both events reference the same old membership checkpoint. Under this candidate representation, the receiver can see byte-identical payloads and valid signatures in either history. A signature and signer-selected causal parents alone cannot establish the event's real issuance order. The native checks demonstrate this limitation; they do not establish that every possible protocol has it.

The signing implementation matters to the equality check. BoringSSL's Ed25519 signer is deterministic, while [CryptoKit randomizes Ed25519 signing](https://developer.apple.com/documentation/cryptokit/curve25519/signing/privatekey/signature(for:)). CryptoKit verifies the BoringSSL signatures in this probe. Randomized signatures also provide no authenticated issuance-time evidence, but this probe makes the narrower byte-equality claim only for the pinned BoringSSL signer.

The former policy said legitimate concurrent mutual removals both take effect. If the design accepts either event solely from the shared old membership, it also accepts the indistinguishable fabrication. With only A and B enrolled, applying both leaves no trusted endpoint. This consequence is reasoned from the former policy; no receiving membership state machine or lockout is executed by this counterexample. B must be able to reach a receiver that honors concurrent mutual removals rather than rejecting every event from a locally removed issuer.

The payload has no per-author sequence/self-parent chain. Such chains can expose some equivocations when the necessary history has been witnessed; they do not supply independent issuance-time evidence for an unseen branch. Gordon subsequently chose trusted ordering for removals, replacing automatic application of both mutual removals. One ordering server handles removal commitment; it waits when that server is unavailable. Previously verified offline local/direct access continues. A separate replacement/quorum requirement was declined.

## Single-authority ordering candidate

The harness now builds a native Rust `ordering-server` and native Swift `ordering-client`, then runs `ordering_checks.py`. The server serializes signed removal requests, rechecks the issuer against the preceding committed membership and signs a hash-chained receipt. It appends the complete request and receipt and calls `sync_all` before acknowledging the commit. Stable issuer/request IDs bind retries to the same operation. The journal is replayed and cryptographically checked on restart, and a Unix OS lock prevents two processes writing the same journal. The native Swift helper signs requests and verifies receipt signatures; it does not validate and apply the full receipt chain.

This is a candidate with one explicitly pinned account server acting as removal authority. The relay is not that authority. Account bootstrap, initial membership and authority designation are trusted fixtures. The authority's test seed is kept in the Python driver's memory and delivered over stdin again on restart; no product key store is implemented. Neither fixtures nor public journal records are a production credential workflow. Host-language secret copies are not all erased.

`ordering-results.json` records executed checks, including competing mutual requests in both arrival orders, requests from removed keys, altered signatures, account/epoch/purpose binding, unknown targets, retry/nonces, stale bases, receipt signature verification by native Swift, ordinary restart, process exit after sync but before acknowledgement, journal tampering/truncation and the OS writer lock. The crash fixture tests process-exit recovery, not physical power loss or filesystem durability guarantees. Removing the authority is rejected until an explicit transfer is provided; transfer is not implemented.

An important negative control restores the original journal while retaining the authority key. That restored process can sign a conflicting valid receipt. The harness saves a checkpoint and actual `STATE` responses from that native process, then starts fresh Python reference-verifier processes to identify the lower-sequence rollback and equal-sequence fork. This is not a Swift product checkpoint implementation. The fixture authority pin comes from trusted harness bootstrap; authority discovery/pinning is not independently tested. A signed chain detects conflicts relative to retained evidence, but cannot prove global freshness or prevent a trusted authority from equivocating. New clients cannot bootstrap safely from the relay's claim alone.

Any incomplete journal tail fails closed and requires manual repair in this prototype; automatic torn-tail recovery is not implemented. The native helpers use trusted local pipes with line-size checks after buffering. They must not be exposed as network services: bounded streaming framing and resilient malformed-input handling remain unimplemented.

The candidate assumes a single honest, non-equivocating authority with its current journal, no cloned key, no old-snapshot signing and no automatic failover. Gordon accepted this availability model and declined a separate replacement/quorum requirement. Removals wait if the authority is unavailable; another server is not promoted automatically. Permanent loss of its key/current history has no safe unilateral replacement in this mechanism. Server-backed work requires a reachable server, including the local server on Mac. Offline reusable deployment enrollment is not implemented by this sequencer and is not being changed to require it online.

## Additional policy inputs agreed with Gordon

- Unfamiliar admissions signed by a removed authority need fresh approval unless surviving endpoints hold verifiable prior acceptance. Removal also wins against acceptance that cannot be proven to precede it, including acceptance by a disconnected witness. A legitimate approval already witnessed during a partition may therefore require fresh approval after reconciliation.
- Expiry or revocation of an enrollment/deployment credential prevents future enrollment; it does not automatically remove servers already enrolled through it. Verifiers cannot enforce a revocation they have not learned.
- Gordon accepted a fresh-approval exception for previously unseen enrollment first presented after its credential expires or is revoked, including a legitimate server enrolled while every existing endpoint was offline. Already verified servers stay enrolled.

## Directory-key delivery and offline bootstrap

The harness builds a native CryptoKit sender and native Rust/BoringSSL recipients using authenticated HPKE with P-256/HKDF-SHA256/AES-256-GCM. CryptoKit encrypts a fresh directory-content key to each recipient and encrypts a fixture directory snapshot with that key. Rust/BoringSSL authenticates the key envelope and integrity-checks the snapshot under the shared content key. Snapshot origin needs signed records: every holder of that content key could otherwise create a different AES-GCM snapshot. This checks independent cryptographic implementations, unlike the shared TLS/PAKE core.

Contexts bind the account, epoch/checkpoint fixture and recipient key. Checks cover altered keys, encapsulations, snapshots, account/checkpoint substitutions, wrong recipients, unapproved senders and stale contexts. A fresh content key excludes the removed recipient from new envelopes. That recipient still decrypts retained old ciphertext, which is the expected limit of revocation. It cannot open another recipient's new envelope.

The offline-bootstrap check supplies a prepared envelope to a deployment-holder key, stops the original sender process and has the holder rewrap the key to a new independently generated recipient. The new recipient authenticates the holder and opens the prepared snapshot. Cached keys remain bound to their original context, so the holder cannot relabel an old key with a newer checkpoint.

Authority, delegation and epoch pinning are fixtures in these cryptographic checks. They do not implement real credential-secret provisioning, signed-account receipt validation, a durable keystore, directory-record signatures/version convergence or membership-driven recipient selection. HPKE storage envelopes do not provide forward secrecy against later recipient-private-key compromise. Per-snapshot keys and account-approved key-purpose bindings still need integration with real membership state and transport.

## Signed account and enrollment reference model

`enrollment_checks.py` uses real native CryptoKit signatures and native-generated recipient keys, with the account policy and injected clock running in Python. It checks a first-client-signed genesis, an anchor stable across first-client removal, signed identity/recipient-purpose bindings, account-owned reusable delegation, server-only scope, creator-removal survival, expiry/revocation behavior, finalized versus unseen admissions, and explicit rejection of old removed-server evidence. It is a reference model, not a production Rust membership engine or a live passkey ceremony.

Reusable delegation proofs are created without contacting the authority; their later validation uses the agreed current credential and late-approval rules. A cached-trust view verifies the delegation and admits it locally, and the new server approves a client while calls to the old authority's signing/verification helper are forbidden. This demonstrates reference-policy offline authorization, not a live network workflow. Credential issuance is registered in the reference authority first. Recognized servers authenticate with their own bound identity and do not inherit credential expiry. The model rejects late, previously unseen records after expiry/revocation, and a current trusted endpoint can freshly approve such a server.

Each verifier uses its own trusted current clock when first validating a credential; it ignores the subject's claimed issuance time. A previously authorized independent endpoint issues the normal server-admission certificate when it verifies a valid delegation in a live subject-proof exchange. Later forwarding returns that original certificate, without creating a post-expiry signature. Its accepted issuer can still authorize that server, while an unrecorded certificate from a removed issuer needs fresh approval. Forwarding uses an ordinary admission certificate; a credential tag is an audit label and no signer-controlled timestamp proves issuance time. A new server derived only from the same credential is not independent authority for its own backdated enrollment.

Generic single-use invitations use a dedicated trusted online issuer. A subject signs its request with its own key; the issuer verifies the request and secret, serializes allocation through SQLite `BEGIN IMMEDIATE`, signs and persists the resulting admission before returning it. Two concurrent subjects cannot both redeem the same invitation. Exact retries return the original allocation, including after invitation expiry; that issuer already verified the winning server. This assumes an honest issuer with its current database. Rollback, cloning, issuer compromise, real process/power-loss recovery and network transport are not demonstrated.

The model strictly checks purpose domains and exact signed-field sets before the issuer signs a request. Genesis ingestion has a path for supplied evidence under an existing anchor pin. Concurrent single-use attempts start at a barrier before SQLite allocation. The membership ledger is in memory and independently signed, while native Rust journal durability is covered by the separate ordering probe. Full recursive provisional-admission propagation, account-state encryption, real signed-record replay and native client persistence remain integration work. This suite does not establish security of the whole composed account protocol.

## Native TLS channel and process-continuity probe

The same command builds a Rust channel server and Swift channel client around pinned BoringSSL TLS 1.3. Both peers authenticate the expected Ed25519 public key from a trusted fixture; they also check the disposable certificate's validity interval. The probe explicitly configures Ed25519 signing/verification, disables early data, tickets and session caching, and checks that handshakes use TLS 1.3 without session reuse. This is shared-library FFI interoperability, not a comparison of independent TLS implementations.

The Python fixture forwards opaque TLS bytes between native processes, including arbitrary fragmentation. It does not deploy or exercise a real relay, WebSocket adapter or network route. The Rust server owns a real `/bin/sh` process with pipe I/O, and encrypted marker round trips verify its PID and exact UTF-8/ANSI output before and after traffic-key updates and fresh authenticated connections. It is not a PTY, terminal-state synchronization or production attachment/control test.

`channel-results.json` records identity-substitution rejection, modified/stale/replayed record rejection in both directions, traffic-key updates from both endpoints, fresh handshakes and shell continuity. Native TLS message callbacks observe KeyUpdate messages being sent and received. A hashed exporter observation is compared across peers and connection replacements. This observation is not a traffic key, and the tests do not extract TLS traffic secrets or prove forward secrecy/post-compromise recovery. Standard TLS properties remain subject to correct composition and review. Updates and reconnections are explicitly triggered; automatic scheduling is not implemented.

Late packets and update requests after channel failure return an error without terminating the server or its shell. The memory-BIO adapter does not implement fatal-alert forwarding, `close_notify` or truncated-transport EOF handling. Certificate expiry/future-date rejection and copied-certificate/wrong-private-key attacks are not negative-tested. Self-signed certificate dates are not revocation authority; account membership must provide that policy.

The locally runnable workload records an initial handshake, three fresh handshakes and handshake-to-echo intervals, marker round trips before updates, update-plus-echo intervals from both endpoints, and repeated 256-byte/4-KiB output round trips. Timings include local fixture IPC, certificate setup and shell echo. They are regression observations, not network latency, isolated cryptographic costs or production performance budgets.

## Interpret the results

`PEER_VERIFIED` means that one endpoint verified its peer's confirmation. It grants no account membership. A relay can drop or replace one confirmation so one peer verifies the other while its counterpart rejects or times out. The final admission operation must handle incomplete exchanges and retries explicitly.

The checks cover matching inputs, a wrong code, account substitution, changes to either endpoint's key, request substitution, client-to-server role substitution, replayed exchange messages, reflected confirmation, replayed confirmation and a non-hex exchange message at either native endpoint. Replay cases reuse the original secret and binding with fresh ephemeral exchanges. Assertions check both peer verdicts, including the expected asymmetry when only one confirmation is replaced.

The Rust approver additionally limits the request to five exchanges, expires it after five minutes using a monotonic clock, rechecks expiry at confirmation and refuses reuse after verification. Abandoned exchanges spend an attempt; malformed exchanges terminate the disposable request. The harness exercises five failures, refusal after verification and request start immediately before and at expiry. Expiry boundary checks use an explicitly enabled fixture clock; this is not a five-minute wall-clock observation or a check of expiry during an in-flight exchange.

These are executable adversarial examples, not a security proof. Per-case elapsed times include process startup and are not handshake performance measurements.

## Remaining work

- Durable request identity, timeout/abandonment handling and anti-reset enforcement across real endpoint restarts. The primitive probe's request is in memory for one process lifetime; it has no recovery or registration service.
- Stable account genesis, actual endpoint identity generation, signed membership, directory-key delivery and rotation.
- Integrate admission key-possession challenges and uniqueness checks for identity/agreement keys, including revoked-key tombstones. The reference binds supplied public keys but does not complete that ownership/reuse validation.
- Admission ordering, revocation tombstones, durable checkpoints, rollback/fork handling and uncertain admissions from a removed authority.
- Trusted atomic single-use redemption and offline reusable deployment credentials.
- Integrate the demonstrated TLS 1.3 primitives with real membership and transport, automatic refresh/reconnection, full channel-close handling, production attachment state and PTY continuity. Extend the fixture timing workload into representative product measurements.
- iOS/iPadOS builds and native Linux/Windows checks.
- Independent review of the composed protocol and Gordon's reaction before resolving the wayfinding ticket.

No product code, account, relay or deployment is changed.
