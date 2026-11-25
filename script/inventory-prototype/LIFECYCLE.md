# Native Mac agent lifecycle checkpoint

This follow-up uses real installed CLIs in native macOS pseudoterminals. It found reporting gaps and does not close [inventory and activity validation](https://github.com/GordonBeeming/myterm/issues/165). [Repair native agent question and cancellation activity reporting](https://github.com/GordonBeeming/myterm/issues/185) now blocks that validation.

## Results

The current app's selected agent/hook/parser/foreground suite passed 297 tests:

```sh
swift test --filter 'Agent|NativeAgentHooksTests|CodexHooksTests|TerminalSessionConfigurationTests.testForegroundProcessDetectionIgnoresIdleShellAndFindsActiveJob'
```

The live observations are separate from that regression count:

- Codex 0.160.0 displayed a blocking Plan-mode `request_user_input` question for 84.617 seconds while its native MyTerm reports stayed Working. No AwaitingInput appeared anywhere in the captured question session, including answer handling and clean exit.
- Claude Code 2.1.325 returned to an empty composer after declining a question, while its last native report remained AwaitingInput. Its own transcript bounds the cancellation-to-next-prompt interval at 181.348 seconds. Rejected command permissions also lacked a clearing report in the observed runs.
- Claude's two requested shell calls remained independently gated. The first approval created `myterm-permission-a.txt` containing `ALPHA`; the second was still pending and its file absent. Rejecting the second did not create its file. This does not establish reliable per-request native identifiers or cancellation reporting.
- Antigravity 1.5.9 emitted Waiting and completion for questions and their skip path. Its real command dialog was observed before approval with the proof file absent. Choosing the one-time approval produced the eight-byte `APPROVED` file and a Finished report. The pre/post records contain the screen excerpts, file hashes, marker offsets, actual Enter key hash and satisfied Finished wait. A separately driven denial returned Finished as a manual observation; that early action record has no automated satisfied-result field. A sign-in permission warning was present; authentication was not repaired or reset.
- Grok 1.0.77 emitted Waiting, answered completion and interrupt/completion for questions. Its harmless command ran without a permission dialog under its current policy. Manual command approve/reject coverage remains unverified.
- Codex command approval emitted AwaitingInput, Working and Finished, and the proof file was created. The request resolved without a driver approval decision, so this is not manual approve/reject coverage.
- Corrected startup/input-screen forced-exit probes passed once for Claude, Codex and Grok, including computed zsh PID output and an empty killed foreground group. Antigravity's latest run encountered an OS `Operation not permitted` error and remains inconclusive. All four recorded their owned cleanup groups empty. Busy-turn killing, the real MyTerm widget fallback and separate/shared provider daemons are outside this proof.

The initial forced-exit output check could match the typed command's echo and was rejected during independent review. It now asks the shell to compute its output and include its actual PID. Another Antigravity attempt exposed a delayed terminal-query reply being sent into zsh after the CLI died; the harness now stops those replies before killing the originating CLI and waits for an input screen first. The final Antigravity OS error is retained as a failed/inconclusive probe, not silently treated as a pass.

## Evidence

`evidence/lifecycle/native-captures.json` retains sanitized native payloads, raw-source hashes and pointers to private raw files. These are manually driven, exploratory compatibility observations. Driver action labels alone are not assertions. Early diagnostic iterations do not contain the later instrumentation fields; their observations are backed by retained terminal bytes and the test's own provider transcript boundaries.

`screen-evidence.json` contains reconstructed terminal-cell excerpts, byte offsets, linked capture names, raw and transcript hashes, UTC interval boundaries and all following marker states through exit. `screen_evidence.py` regenerates the excerpts using pyte. These are terminal reconstructions, not native Mac app screenshots. The raw terminal captures include personal status information and remain in a mode-700 directory outside the repository; each raw file is mode 600.

`antigravity-pre-approval.json` and `antigravity-post-approval.json` retain the repeat command-approval evidence. Its permission reports are native status snapshots. The hook's JSON `decision: allow` branch excludes `status` and therefore did not approve that command dialog.

`production-replay.json` records the sanitized reports passing through the current production `AgentActivityMarker` parser and `AgentReportFilter`. Successful parsing does not make a reporting gap a pass. The reporters are observed in trusted local test sessions; this is not adversarial producer or authenticated endpoint evidence.

## Repeat

The interactive diagnostic accepts JSON control records on stdin and prints the private capture directory. It starts only a disposable local session, with existing authentication and MyTerm hooks. Approve a command only after inspecting the actual dialog and its command. The Claude permission case adds a session-only Bash ask rule. Native workspace-trust prompts were accepted only for the owned scratch directories; no global permission rule or hook file was edited.

```sh
python3 script/inventory-prototype/lifecycle_probe.py claude --case question
python3 script/inventory-prototype/lifecycle_probe.py claude --case parallel
python3 script/inventory-prototype/lifecycle_probe.py antigravity --case write
python3 script/inventory-prototype/exit_probe.py codex
```

The drivers consume provider usage when they submit model turns. The foreground exit probe opens a native startup/input screen without requesting a model turn. Its cleanup checks cover the owned foreground group.

After building the package, replay captured reports through its real core module:

```sh
swiftc -I .build/out/Products/Debug script/inventory-prototype/replay_native.swift -L .build/out/Products/Debug -lMyTermCore -o /tmp/myterm-replay-native
/tmp/myterm-replay-native script/inventory-prototype/evidence/lifecycle/native-captures.json
```

Regenerate this retained run's terminal excerpts with a scratch pyte environment:

```sh
python3 -m venv /tmp/myterm-lifecycle-python
/tmp/myterm-lifecycle-python/bin/python -m pip install pyte
/tmp/myterm-lifecycle-python/bin/python script/inventory-prototype/screen_evidence.py
python3 script/inventory-prototype/build_lifecycle_review.py
```

The excerpt generator is specific to these retained captures and their native transcript identities. It makes no model requests. The review page is `/Users/gordonbeeming/Developer/artifacts/myterm/native-agent-lifecycle.html`.

The redesigned Rust/relay/client integration, actual native MyTerm UI acceptance, further provider modes and child-permission coverage, busy forced exits, iPhone/iPad integration and deferred Linux/Windows validation remain open. No production source fix, commit, push, release or deployment was performed.
