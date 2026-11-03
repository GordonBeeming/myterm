# Antigravity and Grok native signal investigation

Checked on 3 November 2026 AEST using official documentation, installed CLI help and embedded documentation, then headless CLI sessions in isolated temporary workspaces. The initial PTY probe verified startup callbacks without a model turn. Later live turns captured question and lifecycle payloads; see the runtime checks below. The test setup used project hooks and a session-only status override, without installing global MyTerm integrations.

## Antigravity

Installed `agy --version`: `1.4.12`. `agy --help` confirms `--settings` can provide session-only settings and `--conversation` resumes by ID.

The documented `statusLine` command receives JSON on stdin when state changes. It exposes `conversation_id`, its compatibility alias `session_id`, `conversation_title`, `transcript_path`, and `agent_state`. States are `idle`, `working`, `tool_use`, `reviewing`, `authenticating`, `initializing`, and `error`. `tool_confirmation_pending` is true while a tool confirmation dialog shows and omitted otherwise. `pending_input_count` counts queued user messages; it does not identify a question awaiting an answer. The documented subagent records contain only `name`, `role`, and `status` (`running` or `completed`). Commands are throttled to 300 ms, killed after five seconds, and disabled after 30 consecutive failures. [Status line contract](https://antigravity.google/docs/cli/statusline/).

The `title` command receives the same JSON. Its stdout becomes a plain terminal title after control-character removal. A wrapper that transports metadata must preserve any existing title or status command and its output. [Title contract](https://antigravity.google/docs/cli/title/).

Antigravity also has native hooks. CLI hooks load from `.agents/hooks.json`, `~/.gemini/config/hooks.json`, and plugins, rather than CLI `settings.json`. Events include `SessionStart`, `PreInvocation`, `PostInvocation`, `PreToolUse`, `PostToolUse`, and `Stop`. Tool hooks receive `toolCall.name`, `toolCall.args`, and `conversationId`. `ask_question` is explicitly listed as a supported tool, so a matcher can distinguish it from other calls. `PostToolUse` occurs after completion and includes an optional error. The contract does not state whether hooks run before a question becomes visible, whether every cancellation produces a matching completion, or how parent and child conversations are correlated. [Hook contract and supported tools](https://antigravity.google/docs/hooks/).

Binary inspection corroborates the `agent_state`, `conversation_title`, and `tool_confirmation_pending` JSON tags. Internal symbols include `SetPendingQuestion` and `PendingAskQuestion`; these are internal implementation evidence, not a public pending-question payload.

The headless PTY probe confirmed that installed Antigravity executes the session-only `title.command` callback and supplies JSON during startup. Captured states were `authenticating` and `initializing`, with empty session/conversation IDs. Raw local evidence: `/tmp/myterm-parity-g9qy_tua/states.jsonl` (temporary, not committed). It did not verify working, idle, question, permission, or child-agent states.

Inference: combining question tool hooks with status metadata is a plausible integration. Full parity still needs live checks for question display, answer, cancellation, and subagent permission requests. The published status schema does not establish whether `tool_confirmation_pending` includes every child permission request, identify its owner, or distinguish a question from an approval.

## Grok

Installed `grok --version`: `1.0.70 (f50904eaee6c) [stable]`. Help confirms resume by session ID or title, explicit session UUIDs, headless output, and subagents.

Official docs confirm personal hooks in `~/.grok/hooks/*.json`, project hooks in `.grok/hooks/*.json`, and compatibility loading from Claude settings. Hook stdin includes `hookEventName`, `sessionId`, `cwd`, and `workspaceRoot`. The web event list includes `SessionEnd`, `Stop`, `StopFailure`, and `Notification`; it does not list `StopCancelled`. [Grok hooks](https://docs.x.ai/build/features/hooks). The installed executable's embedded `10-hooks.md` is more detailed and describes behavior beyond that web page.

Verified in the installed binary's embedded hook guide:

- `permission_prompt` notifications occur only while a permission UI actually waits. Match `notificationType`, since display messages may change.
- `Stop` observes completion but also supports blocking continuation gates. A passive observer cannot distinguish a continuation fire from a final one. A separate `Stop` runs during teardown with `reason` of `channel_closed` or `shutdown`.
- `StopFailure` covers API errors; `StopCancelled` covers interrupts, rejected/cancelled permissions, limits, and other cancellation reasons. `SessionEnd` covers teardown.
- Reports can arrive after the next `UserPromptSubmit`. Track `promptId` within a session and ignore stale reports. Child events carry `subagentType` and should not settle the parent.
- `idle_prompt` is a delayed fallback, approximately one minute after settling. Completed bash-mode commands and some other paths have no immediate completion event. If another hook blocks `Stop`, the guide recommends relying on `idle_prompt` and `SessionEnd` for settlement.
- Claude compatibility files and native personal hooks are merged. Folder trust or managed policy can prevent them running. Dedicated Grok registration must avoid receiving duplicate inherited MyTerm Claude events.

Binary strings also associate `permission_prompt` with tool permission, plan approval, and diff review messages, and `elicitation_dialog` with a user-question message. This establishes that both notification names exist in this version. It does not establish the full question lifecycle or which child-dialog paths emit them.

Reproduce the local evidence without starting a session:

```sh
agy --version
agy --help
grok --version
grok --help
strings ~/.grok/bin/grok | sed -n '/10-hooks.mdHooksProject lifecycle/,/11-mcp/p'
```

Inspected executables: `/Users/gordonbeeming/.local/bin/agy` and `/Users/gordonbeeming/.grok/downloads/grok-macos-aarch64` (the target behind the `grok` command symlinks). Embedded documentation is version-specific and should be rechecked when these binaries change.

## What remains to prove

MyTerm already clears an agent when foreground process tracking reports that its CLI has returned to the shell: `foregroundProcessChanged` calls `forgetAgent` for a live agent ([AppModel.swift:2514](../../Sources/MyTerm/Models/AppModel.swift#L2514)). This provides an existing exit path alongside provider hooks. Persistent-host sessions, process replacement, and forced exits still need runtime tests before relying on that cleanup for every launch mode.

Live validation must check busy, completion, failure, interruption, question open/answer/cancel, permission open/approve/reject, and child permissions. Include continuation gates, queued turns, trust-disabled hooks, clean exit, and forced termination. Capture real payloads before promising Codex/Claude parity. Synthetic adapter tests can verify MyTerm mappings but cannot close these producer-behavior gaps.


## Implementation and runtime checks

MyTerm now registers both agents, reports their activity, retains their conversation identifiers and offers their native resume commands. Antigravity uses native hooks plus a status callback that preserves the prior status script. Configuration changes roll back if either file fails. Grok uses a separate personal hook file and suppresses inherited MyTerm Claude reporters.

Live checks used Antigravity 1.4.12 and Grok 1.0.70 in headless pseudoterminals. Antigravity produced `PreInvocation`, `PreToolUse` for `ask_question`, `PostToolUse` after skipping the question, and `Stop`. Its status callback wrote working and idle OSC reports to the actual terminal. A newly trusted workspace loaded its project hooks after the first invocation; the next invocation used them. Grok produced `elicitation_dialog` notifications, question-tool completion, session and prompt events. Its native `hookEventName` is snake_case while compatibility `hook_event_name` is PascalCase. Actual Grok OSC titles included transient busy text and an idle conversation name followed by ` - grok`; MyTerm keeps the idle name.

Captured test payloads live under `/tmp/myterm-live-antigravity-9mkzlqy4` and `/tmp/myterm-live-grok-_odf37lq`. These are temporary evidence, not repository fixtures. Regression tests cover equivalent payloads, stale events, independent wait tokens, startup/idle behavior, configuration restoration and failed-install rollback. Claude independently reviewed the implementation and identified lifecycle issues addressed during this work.

Live tool-permission dialogs, child-permission dialogs and completion gates that request another turn remain unverified. The Grok test session resolved its requested default permission mode to the account's auto mode, so the harmless test command did not produce a permission prompt. The live checks did not control the MyTerm GUI or exercise a paired companion.


## Final validation

- `swift test --filter 'Agent|NativeAgentHooksTests|CodexHooksTests|PersistentTerminalStartupTests|PersistentTerminalRuntimeTests|LocalProcessOutputDrainTests'`: 304 passed, 0 failed, 0 skipped on macOS. Log: `/tmp/myterm-agent-final-tests.log`.
- `bash script/build_and_run.sh --bundle`: signed development bundle built at `dist/myterm-dev.app`. Log: `/tmp/myterm-agent-bundle.log`.
- `codesign --verify --deep --strict dist/myterm-dev.app`: passed. Both new adapter resources are present in the bundle.
- `git diff --check` and `/bin/sh -n Resources/myterm-agent-hook Resources/myterm-antigravity-status`: passed.
- Claude Sonnet independently reviewed the diff and the fixes in three rounds. Its final report found no remaining concrete defects in the reviewed fixes. Report: `/tmp/myterm-agent-review-final.json`.

No MyTerm GUI, simulator or physical-device validation was performed. No screenshots were captured.
