# Deployment enrollment prototype

Disposable native Rust protocol evidence for [Validate deployment credential expiry, revocation and offline enrollment](https://github.com/GordonBeeming/myterm/issues/193). This is research on the map branch, with no product integration or shared deployment.

## Run

```sh
python3 docs/wayfind/125/deployment-enrollment/probe.py --output /private/tmp/myterm-193-results
```

Requires Rust/Cargo and Python 3.12+. Cargo builds the locked dependency graph offline into `/private/tmp/myterm-193-build`; dependencies must already be cached. Choose another build directory with `--build`. The harness uses OS-assigned loopback ports and temporary journals. All native processes and temporary journals are cleaned up after the run. Source hashes and the machine/toolchain are recorded in `results.json`. The only persistent outputs are the selected results directory and build cache.

## What runs natively

The Rust binary runs as an authority or endpoint. This bounded probe permits 16 credentials and 64 lifetime server identities, reserving journal-record space for revocations and tombstones. Those are experiment limits, not proposed product quotas. Removed identities still occupy slots; a leaked credential can exhaust this experimental account’s future enrollment capacity. Product storage design needs abuse limits and safe retention/compaction rather than this lifetime cap. Explicit tombstones can target a provisionally known identity before canonical admission, subject to the same experiment capacity. Endpoints generate fresh Ed25519 keys through the OS RNG, sign server enrollment requests, create credential-holder delegation signatures, and verify pinned-authority credentials and directories. The authority validates both server key possession and delegation, records single-use allocations and memberships in a signed hash-chained journal, and synchronizes the journal before acknowledging changes. An OS file lock excludes a second writer. A mutex serializes concurrent TCP redemption against the same state.

A credential belongs to the account. Its creator and provisioning holder are separate identities; removing its creator prevents new issuance attributed to that creator but preserves existing credentials. Creator attribution is checked natively; operator authorization still comes from the trusted pipe. Replacements use new credential IDs. Single-use allocation is tied to the entire signed server request, so an identical retry recovers its admission without allocating another identity. Native responses distinguish canonical membership from provisional local recognition. Expiry and credential revocation leave canonically admitted servers enrolled; explicit server removal leaves a tombstone.

An endpoint can verify reusable delegation using a cached, signed directory while the authority and the prior observer are stopped. The offline credential holder remains a provisioning process, without current account membership. Its proof and the new server's key-possession signature are verified by a separate native process. This does not exercise an authenticated terminal connection, encrypted directory-key delivery or account bootstrap from an untrusted relay.

The Python driver starts native processes, forwards public signed artifacts, injects fixture clocks and asserts results. It performs no enrollment-policy or signature verification. Most boundary checks use an explicitly enabled native fixture clock; separate five-second credentials exercise successful admission and subsequent expiry against normal native wall clocks.

## Review decisions

Gordon agreed that single-use redemption requires the designated account server online. Reusable delegation remains offline-capable. Reusable credentials warn within seven days, within one day, and at expiry; only the most urgent current status is shown. A shorter-lived credential enters the relevant warning window immediately. Warnings do not modify expiry.

The walkthrough separates live probe results from its interactive model. The model is a discussion aid and does not run native cryptography.

One reconciliation behavior needs live review: a server recognized only provisionally through an offline credential remains recognized locally across expiry, but a newly delivered revocation invalidates that provisional recognition unless the authority has already recorded the server's admission. A locally claimed timestamp cannot prove that admission preceded revocation. This applies the existing conservative ordering rule; the probe adds no trusted clock or quorum.

## Evidence and limits

The first independent review found that unbounded full-state records could eventually prevent revocation. The prototype now bounds credential and lifetime identity growth before the record limit; saturation checks require successful revocation and server removal at capacity. Production storage design and quotas remain implementation decisions.

`evidence/macos-arm64.json` records 94 passing native checks on macOS ARM64, including the executed checks and exact source hashes. This result was rebuilt in a fresh build directory. The source review reports are retained alongside it. Claude’s final read-only review found no blocker for a research checkpoint and verified that the retained result and embedded walkthrough match the current native and driver source hashes. It did not independently execute the suite or audit the composed protocol. The race timing includes thread startup, local TCP, native signature checks and journal synchronization; it is a local observation, with no release latency budget selected.

Bootstrap roots, authority designation and operator authorization use trusted fixtures and private process pipes. The operator pipe can approve an endpoint directly; no user approval ceremony is implemented here. Fresh trusted approval is an independent admission, not another redemption of a consumed credential. Its request references a known historical credential and cannot overwrite an existing identity record. Ed25519 credentials and signatures are real, but no composed-protocol security audit is claimed.

The loopback TCP listener carries public signed enrollment records in plaintext. It must not be exposed as a product enrollment service. It has bounded frames and timeouts but no connection/thread admission limit, TLS, account authentication or private-directory encryption. The actual relay-access control is not wired: an enrollment flag demonstrates explicit intent only. Existing account-trust probes retain the separate HPKE, approval and TLS evidence; this probe does not establish their secure composition.

Endpoint keys, directory caches and provisional admission records live in process memory. Restart durability is tested only for the authority journal; production endpoint key storage, persisted checkpoints and bootstrap freshness remain open. Journal replay checks signatures and sequence continuity relative to the supplied root, but cannot detect a coherent old journal restored with its original signing key. Process exit before writing and after sync is tested; filesystem power loss, disk-full recovery and old-snapshot signing are not accepted by this experiment.

The authority floors its wall clock by elapsed monotonic time within one process. Across restarts, the experiment assumes an honest system clock; it does not solve clock rollback or establish trusted external time. An honest verifier with a stale directory can accept a credential whose revocation was withheld. No maximum propagation delay is promised.

The fixture contains signed names and identities, with no production runtime sessions. Same-name enrollment preserves separate directory entries; session survival, session ownership, server liveness UI, golden-image provisioning and product discovery integration remain untested. No native Linux/Windows, physical-device, multi-Mac or Azure VM scale-set run is claimed.

Production acceptance remains in [Validate production account trust and channel security](https://github.com/GordonBeeming/myterm/issues/178). Real Azure execution remains in [Validate Azure VM scale-set enrollment after basic native connections work](https://github.com/GordonBeeming/myterm/issues/194).
