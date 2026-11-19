# Replicated layout and deferred termination prototype

Open `candidate.html` directly. Its fifteen guided walkthroughs and free-play actions use the same reference model as the checks. This is a throwaway decision artifact, separate from the production app.

```sh
python3 script/layout-prototype/build.py
node script/layout-prototype/checks.cjs /private/tmp/myterm-layout-results.json
node script/layout-prototype/visual-qa.cjs /private/tmp/myterm-layout-qa
```

The builder embeds `model.js` and `scenarios.js` into one self-contained page and copies it to `/Users/gordonbeeming/Developer/artifacts/myterm/layout-convergence-prototype.html`. The headless visual runner needs the locally installed Playwright/Chromium. Inspect its captures before deleting them.

The checks cover deterministic delivery permutations, independent and conflicting edits, causal gaps, duplicate and forked operations, stale edits after deletion, mixed-server closure, failed submission, queue expiry, runtime incarnation matching, authorization failures, removed servers, attachment ordering, local focus, structural recovery, model restart/transaction boundaries and storage-budget refusal. Real Node Ed25519 checks verify typed operation-byte binding with disposable keys; they are separate from the model's fixture security adapter.

Gordon accepted these product choices in conversation:

- Stale or unknown process status requires confirmation; a fresh idle-shell report closes immediately.
- New terminals unseen by a concurrent workspace close survive in recovered structure.
- Automatic process cleanup requires explicit authorized deletion evidence for the exact runtime, rather than inferring deletion from snapshot absence.

Gordon accepted the candidate after reviewing the page: 30-day losing-edit recovery with unacknowledged data pinned, account-lifetime minimal tombstones, transactional checkpoint compaction and fail-closed resource budgets. The accepted fork policy pauses new attachments and destructive cleanup account-wide until trusted checkpoint repair; existing processes keep running. Revocation alone does not repair ambiguous history, and this prototype has no checkpoint-repair action. The model retains source operations and does not perform destructive history garbage collection. Its 10,000-operation/8-MiB limits exercise rejection behavior, with the first ceiling reached taking effect. Full dependency lists make model storage quadratic and will hit the byte ceiling first; these are not representative production allowances. Structurally valid rejected operations retain their payload in a bounded recovery quarantine. Missing-dependency operations are buffered and retried without an acceptance acknowledgment. Both dependency and recovery buffers enforce a 32-record/64-KiB cap per known issuer. Unauthenticated or unknown-issuer payloads are dropped. The prototype schema has no forward compatibility; unsupported input is not acknowledged and the sender retains its original record.

The model supplies signature verification, membership validation, complete-snapshot checks and a nonce-bound live channel as fixture facts. Its restart action copies modeled durable state. It does not exercise native persistence, process handles, encrypted storage/transport, membership-ledger integration, true crash recovery or globally latest state. Direct peers use their latest known verified membership, retaining the already accepted limit that withheld updates can delay revocation. Stale or revoked deletion issuers require a fresh authorized endorsement before cleanup; that recovery path remains a production gate.

Production acceptance needs Swift/Rust replay interoperability, actual transactional crash injection, encrypted relay state and queue tests, complete-manifest verification, current trust-ledger integration and endorsement, two-Mac cleanup with real runtime handles, direct-only partitions, stale-client checkpoint compaction and resource measurements. Inventory/agent-activity integration remains in its own validation ticket.

Sources: [Validate replicated layout convergence and deferred termination](https://github.com/GordonBeeming/myterm/issues/156), [Choose shared workspace synchronization and migration](https://github.com/GordonBeeming/myterm/issues/131), [Prototype mixed-server connection and close states](https://github.com/GordonBeeming/myterm/issues/157), [Validate the account trust protocol and approval ceremony](https://github.com/GordonBeeming/myterm/issues/141), and [Choose the first cross-server session and agent view](https://github.com/GordonBeeming/myterm/issues/135).

The accepted sources remain uncommitted in the current worktree. The [resolution](https://github.com/GordonBeeming/myterm/issues/156#issuecomment-6844040718) records the decision; [production layout synchronization and safe runtime cleanup](https://github.com/GordonBeeming/myterm/issues/182) tracks remaining implementation and acceptance. No production source, release or deployment is changed. Retained run evidence records source hashes so an earlier review or passing run is not confused with a later revision.
