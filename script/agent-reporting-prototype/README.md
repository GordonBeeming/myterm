# Native agent reporting fix prototype

This disposable prototype investigates [Repair native agent question and cancellation activity reporting](https://github.com/GordonBeeming/myterm/issues/185). It establishes native signal routes for the two captured failures and runs a candidate adapter against those signals. It does not install a global plugin or replace the production MyTerm reporter.

## Native findings

Codex 0.160.0 emits `PreToolUse` for blocking `request_user_input`, with a native `tool_use_id` and `turn_id`. Its matching `PostToolUse` supplies the same identities after an answer; `Interrupt` identifies a cancelled turn. This supports a targeted question hook route while retaining existing command-permission handling. Nonblocking `request_user_input_async` is deliberately excluded from the wait mapping. The [official hook reference](https://learn.chatgpt.com/docs/hooks#pretooluse) describes the event contracts; the installed version was checked directly.

Claude Code 2.1.325 command hooks emitted `PostToolUse`, `PostToolBatch` and `Stop` for an answered question, but none of those after a declined question. Its native CLI mod API emitted `turn.complete` in that path. A declined question in the observed run had `reason=answer` and `isAborted=false`, so the candidate clears the wait to Finished. A true `aborted` turn maps to Ready. The mod also supplies actual call IDs through `tool.call` and `tool.check`. See the [native turn lifecycle reference](https://code.claude.com/docs/en/plugins/mods/events#follow-a-turn).

The live before/after checkpoint retained in `evidence/live-after-cancel.json` has the legacy reporter still AwaitingInput while the candidate is Finished with zero pending requests. The candidate consumes native lifecycle fields, never terminal prose, transcript content or inactivity timers.

Two Bash calls shared an actual assistant message and had distinct native call IDs. Approval/callback handling was sequential in this run: only ALPHA was written after the first approval, the second still waited, and BETA remained absent after rejection. Controlled delivery replay holds the first completion while delivering the second wait, then verifies that releasing or duplicating the first completion cannot clear the second. That overlap is a replay test, not a claim of live simultaneous callback scheduling.

## Run the retained checks

No provider request is needed for these:

```sh
python3 script/agent-reporting-prototype/verify.py
python3 script/agent-reporting-prototype/check_state.py
node script/agent-reporting-prototype/check_mod.mjs
```

`verify.py` checks native-event prefixes and controlled reordering separately, then sends the candidate snapshots through MyTerm's production `AgentActivityMarker` and `AgentReportFilter`. It uses the replay executable built by the earlier lifecycle checkpoint. Rebuild it when needed:

```sh
swiftc -I .build/out/Products/Debug script/inventory-prototype/replay_native.swift -L .build/out/Products/Debug -lMyTermCore -o /tmp/myterm-replay-native
```

The old bad-report baseline remains red because production sources have not been changed:

```sh
python3 script/inventory-prototype/check_reporting_gaps.py
```

The protocol fixtures and Node API mocks are labelled separately from native compatibility evidence. They cover stale/duplicate identities, session transitions, compaction, explicit unsupported-route invalidation, child ownership and observer failures preserving results, errors and denials. Corrupt-history fault injection also confirmed withdrawal of the stale candidate state instead of replaying incomplete evidence as healthy.

## Repeat the native probes

These submit real model turns and consume provider usage:

```sh
python3 script/agent-reporting-prototype/native_probe.py codex
python3 script/agent-reporting-prototype/native_probe.py claude --mod
```

The driver takes JSON control records on stdin and prints its owned private scratch directory. Inspect the actual native prompt before sending keys. Codex observers are invocation-only inline hook definitions, reviewed/trusted through the normal native hook UI. No hook-trust bypass is used. Claude's native mod is materialized into that run's private directory and loaded with `--plugin-dir`; its settings are invocation-only. The source plugin folder is a template, not an installable package.

`observe.py` retains full native hook inputs only in the private scratch directory and computes `candidate-state.json` under a file lock. `export_evidence.py` is this run's recorder and contains its specific scratch paths. Re-export only while those paths exist. Its saved sanitized fixtures remain replayable later, and private raw inputs/terminal bytes are retained in a mode-700 artifact directory with mode-600 files.

## Limits before production integration

- The Codex candidate is focused on blocking questions and turn interruption. A command-approval event emits an explicit unsupported-route control record with no usable activity payload. Consumers must withdraw its authority for that route, not keep the last snapshot. Production must retain/compose the existing Bash adapter and validate the resulting single authority.
- Claude's mod API is early access. Production needs deliberate packaging/enabling, compatible-version checks and a visible fallback if the mod or observer is unavailable. Error-path safety changes have mocked API coverage; the native producer events and live state comparisons were collected iteratively in the same disposable session.
- This event path has no separately established approval-resolved signal before a long tool finishes. As modelled, an approved long-running tool stays Waiting until tool completion. Short scratch commands do not validate full long-tool activity timing.
- Native session-start control boundaries are assumed ordered at the producer. Replay tests do not establish authenticated remote ordering or recovery. An exploratory Codex `/clear` dropped the invocation-only observer definitions from the new thread, so clear/resume integration was not established by that run.
- The adapter emits aggregate snapshots. They must not be double-counted with the old raw reporter. Exported identities are anonymized for parser replay; production must preserve real conversation/resume metadata securely.
- Real MyTerm UI integration, install/refresh behavior, detached recovery, native subagent behavior, other modes/versions and deferred server/client platform acceptance remain open.

The passive mod returns each native policy decision and tool result unchanged. Observer failures are retained as diagnostics and invalidate the capture. The logger requests a 1000 ms host-process deadline; real-host timeout enforcement was not measured. The private state is withdrawn before a new log event is committed; a corrupt native history withdraws the old candidate state. These are prototype safety properties, not a production durability or performance result.

The self-contained review page is generated with:

```sh
python3 script/agent-reporting-prototype/build_review.py
```

It is saved to `/Users/gordonbeeming/Developer/artifacts/myterm/agent-reporting-fix-prototype.html`. Sources and evidence remain uncommitted. No production source fix, publication, deployment or release was performed.
