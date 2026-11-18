# Local-first enrollment experiment

Bounded native evidence for [Validate local-first enrollment and workspace merging](https://github.com/GordonBeeming/myterm/issues/162). Gordon approved this narrower experiment because the redesigned MyTerm account-join workflow is not implemented. Product acceptance remains open.

## Run

```sh
python3 docs/wayfind/125/local-first-enrollment/probe.py --output /private/tmp/myterm-local-first-results
```

Requires macOS, Rust/Cargo with the locked dependencies cached, and Python 3.12+. The command builds offline into `/private/tmp/myterm-local-first-build`; override it with `--build`. Native processes communicate through private pipes. Temporary account files and experiment keys are created under a private temporary directory and removed after the run. The native runtime owns a real `/bin/sh -i` on a PTY, and closes that disposable shell when the run ends. No MyTerm application state, relay deployment or user terminals are used.

The Python driver forwards signed messages, restarts the authority at named fault points and checks observations. Rust implements signature verification, admission, merge policy and disk persistence. Local runtimes take no account configuration to start; neither native role opens a network socket. This establishes local independence by construction, without measuring the production app's network traffic.

## Candidate behavior

A local server signs its exact content batch, including account generation, operation identity, server identity, public key and first/return mode. The native authority's private operator pipe stands in for an already trusted approver. It signs an approval bound to that exact batch. Missing approval and a login flag both fail signature validation. No relay login or OS-access admission flow is implemented. Ed25519 signatures cover this program's deterministic serde_json reserialization, rather than arbitrary incoming wire bytes or an interoperable canonical JSON specification. The approval ceremony remains a fixture.

For first join, approval is required. Content keeps its IDs, workspace IDs, assigned server and runtime identity. The authority validates the whole batch before writing. Conflicting content or workspace IDs reject the whole operation without changing account state. Same workspace names with different IDs remain separate. Contradictory names for one workspace ID are rejected. Existing mixed-server content is retained.

The membership, content and operation receipt live in one snapshot. The authority backs up the original bytes, syncs the backup, writes and syncs a replacement snapshot, renames it and syncs its directory before returning success. Its OS file lock excludes a second writer. Five original snapshots remain after a successful commit. Pruning or final retention-sync failures can return an error after the main snapshot is durable; join retries recover through their receipt, while the experiment's other operator mutations have no receipt. An identical operation retry recovers the committed result; reusing a server-scoped operation ID with different bytes fails. Revocation and the account-deletion flag are checked before receipt recovery. Account deletion here denies admission only; it does not erase content, keys or backups.

A returning member signs a new batch using its existing identity. Explicit content tombstones prevent resurrection; absence alone never deletes account content. New offline content is additive. A tombstone with a different assigned server or runtime causes rejection. This experiment performs no process cleanup: authenticated exact-runtime termination remains a separate acceptance requirement.

## Evidence and limits

The retained macOS ARM64 run passes 129 native assertions. The Browser.app check covers 52 discussion states at actual viewports 1920×1080 and 390×844, with no horizontal overflow or mojibake. Checked text/background contrast is at least 5.35:1. Reproduce those page checks with `python3 docs/wayfind/125/local-first-enrollment/visual_qa.py <page-id>` after opening the generated walkthrough in Browser.app.

The retained JSON lists each passing assertion and hashes the native source, driver and Cargo inputs. It covers missing approval, altered signatures and approval binding, cross-account/generation attempts, stable identities, same-name workspaces, duplicate retries, content collisions, revocation, the account-deletion flag and five-backup retention. Rejection cases assert the expected error as well as unchanged state. Observations retain original/final PTY responses, the lost-ack receipt and committed content IDs. Shell markers are octal encoded, so terminal input echo cannot satisfy the output check.

The independent runtime's PTY remains responsive with the same PID alongside authority changes. There is no authority-to-runtime cleanup path, so these checks establish harness liveness and separation only. They cannot catch a production enrollment path that accidentally replaces a runtime or terminates work. No claim of integrated migration process safety follows from them.

The run also starts another native runtime with the local server's name but a different key, checks that returning membership rejects it, then confirms clean shutdown and reaping of all three experiment shells. An unused PTY initially held shutdown open; the native runtime now closes its master before killing and reaping its owned shell.

Named interruption points call process exit before commit and after durable commit but before acknowledgment. Additional tests block actual filesystem paths to produce backup and snapshot open errors. A third injection stops the writer after rename, at the directory-sync boundary. Real post-rename sync errors use that same fail-stop policy, preventing stale-memory writes; after restart, the probe checks receipt recovery and preservation by later writes. The injected exit does not establish how an actual filesystem sync error or power loss behaves. Disk-full handling and other crash boundaries remain untested. A process killed after commit can leave extra backups until the next successful commit; production needs startup reconciliation of retention. Failed state writes may leave a valid extra backup of the unchanged original state.

This is a small standalone protocol candidate. It does not call MyTerm's `WorkspaceStore`, migrate a complete folder/pane/tab tree, install a Settings join action, compose encrypted account-directory/key delivery or implement replicated-layout causal history. Browser content is an identity record only; no browser is launched. Existing account content in the experiment is seeded through another native runtime, on the same Mac. It is not evidence of multi-Mac, relay, iPhone/iPad, Linux or Windows integration.

Runtime keys and local join requests remain in memory. The account authority persists its own experiment key and plain JSON state in private scratch files. Restoring an old backup could restore revoked membership or deleted content; backup restore and rollback detection are not implemented. This does not establish endpoint restart/key storage, encrypted backups, authority designation, fresh approval after revocation, account moves or production capacity/security budgets. Fault controls are available only on the private experiment operator pipe. A returning record must match existing content exactly; one edited item rejects its entire batch, including new items. Field edits and concurrent structural repair belong to the accepted replicated-layout contract, which is not reimplemented here. No inference about missing/deleted items is used to terminate a real process.

The current generic workspace importer creates new identities and merges folders by name. It is unsuitable for this join contract without a separate identity-preserving path. The existing native import and migration tests can protect legacy behavior, but cannot establish account-join acceptance.

Generate the interactive walkthrough with `python3 docs/wayfind/125/local-first-enrollment/render.py`. It embeds the retained native evidence and also copies the page to `~/Developer/artifacts/myterm/local-first-enrollment.html`. Its buttons run a separate JavaScript discussion model. Review the candidate and its integration limits before deciding whether bounded feasibility is settled; keep full native workflow acceptance separately tracked.
