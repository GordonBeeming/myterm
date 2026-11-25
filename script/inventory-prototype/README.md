# Account inventory and agent activity prototype

This disposable native Mac prototype explores [Validate cross-server inventory and agent activity synchronization](https://github.com/GordonBeeming/myterm/issues/165). Gordon approved a Mac-first pass with Linux and Windows unverified and the ticket left open. It does not change production sources or connect its inventory to user sessions.

## Run

From the repository root:

```sh
bash script/inventory-prototype/run.sh --verify script/inventory-prototype/evidence
bash script/inventory-prototype/run.sh
```

The first command compiles Swift 6 and runs the bounded model checks. The second builds and opens a disposable SwiftUI app. `MYTERM_INVENTORY_BUILD_DIR` selects its scratch build directory; the default is `/tmp/myterm-inventory-prototype-build`. Quit the existing prototype before rebuilding its executable. No signing asset, production app installation or user workspace is changed.

After explicit GUI authorization, with that app open:

```sh
python3 script/inventory-prototype/native_ui.py
```

This uses AppleScript to select every scenario and check its visible steps. The native captures show only the prototype window. The computer-use tool failed to start in this session; Gordon explicitly authorized AppleScript as the alternative.

To repeat the external-agent smoke probes:

```sh
python3 script/inventory-prototype/native_signals.py
```

This makes one short model request per installed CLI and can consume provider usage. It uses existing authentication and hooks unchanged. Each CLI runs in a fresh temporary directory and native pseudoterminal. No hook installation, trust bypass or permission bypass is performed. Only normalized OSC metadata and an output hash are retained. The script checks ordered Ready, Working and Finished reports and successful process exit; this does not validate native turn correlation or interactive permission behavior. A missing report in print mode would not establish that interactive signals are unsupported.

## Candidate behavior

Terminal and browser inventory items use stable content, assigned-server and runtime identities. Duplicate server names remain distinguishable; search and filtering navigate to existing fixture workspace, pane and tab targets without taking control. Agent lifecycle is separate from terminal lifecycle. An exited terminal remains listed until its tab closes.

Reading Finished acknowledges the exact completion the view displayed. A delayed read cannot clear a newer completion. Input requests remain visible through reads and unrelated activity, and completing one request cannot clear another. Ready is a startup/idle snapshot within an agent incarnation; it cannot downgrade Working or Finished. A resolved request removes that wait. If Finished was already observed, it remains until a reliable Working/resumed event changes activity or the result is read.

Server-numbered deltas buffer gaps. Obsolete agent-incarnation reports consume their valid stream position without changing activity. Invalid schema, unauthorized ownership and invalid runtime reports are rejected; production normalization must validate those before assigning sequence numbers. The native CLI probes do not prove that normalization contract. In particular, assigning numbers after delayed hooks arrive cannot reconstruct original provider order.

Snapshot receipt does not establish runtime freshness. A connection must reconcile before new reports become current. Terminal loss is monotonic for the exact runtime and cannot be undone by a stale snapshot. Explicit replacement uses a deterministic fixture identity standing in for an idempotent allocation by the assigned server. Closing an item retains a minimal deleted-identity record and removes it from inventory; this prototype has no separate session-history view.

Server-name registers include version and operation identities to demonstrate concurrent merge ordering. Full account-layout validation, authentication and losing-change recovery remain in the accepted [layout convergence direction](https://github.com/GordonBeeming/myterm/issues/156). Conflicting payloads with the same signed operation identity are outside these trusted fixture inputs and require the production repair path.

## Evidence boundaries

`evidence/verification.json` records native Swift model checks and actual CryptoKit/file/process checks. A sealed snapshot is recovered by a fresh native process with no other client running. The disposable key travels through stdin and is never written to disk. The caller-supplied generation floor is a fixture checkpoint; it does not establish globally latest state. The command-expiry check deletes a separate scratch command file using a fixture clock while retaining encrypted current state. It does not prove Cloudflare retention or crash durability.

`evidence/native-ui.json` records AppleScript observations across the eight walkthroughs. Those are native UI checks against fixture inventory and agent events. The separate `evidence/native-signals.json` records real installed CLI versions and observed lifecycle reports. No claim is made that these independent probes feed the new inventory end to end.

The existing app was also checked with:

```sh
swift test --filter 'AgentAttention|AgentLifecycle|NativeAgentHooks|AgentActivityMarker|AgentNotificationInbox'
swift test --filter 'AgentActivityTerminalTests|PersistentTerminalStartupTests.testDetachReattachesSameShellAndReappliesCurrentRuntimeAndFittedGeometry'
```

The first run passed 108 tests; the second passed 9, including same-shell native helper reattachment. These results apply to the existing app, not the future Rust service. Retained logs are in this directory's evidence folder. Independent Claude reviews are static reviews; the reviewer's plan-mode permissions prevented its own build attempt. The lead ran the native verification.

The verifier records a 1,004-item encoding/search sample and snapshot size. Its bounds of 32 buffered reports per item, a report-number ceiling of 1,000,000 and an 8 MiB sealed snapshot are illustrative guards. No production quota is selected. Acknowledgment, tombstone and retired-run compaction remains unimplemented. No performance acceptance threshold is claimed from one local sample.

Human review, real two-Mac/Rust/relay integration, provider request and permission coverage, offline/direct workflows, native iPhone/iPad integration and deferred Linux/Windows validation remain open. The prototype is local and uncommitted. No commit, push, release or deployment is authorized by this work.

## Review page

```sh
python3 script/inventory-prototype/build_review.py
```

This exports one standalone HTML file to `/Users/gordonbeeming/Developer/artifacts/myterm/inventory-activity-prototype.html`. Its buttons replay recorded Swift outputs; the interactive native model remains in the Mac app. The page embeds native before/after captures and lists the remaining validation work.
