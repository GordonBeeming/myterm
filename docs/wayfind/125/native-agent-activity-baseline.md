# Native agent activity in the MyTerm development app

Live Mac check on 24 November 2026 AEST. The signed development bundle was built from `0989508` with `bash script/build_and_run.sh --bundle` and run on arm64 macOS 27.3 (26C5047e). The window used a disposable home, application support directory and preferences suite. Both CLIs used existing sign-in and a disposable working directory.

## Claude Code 2.1.331

Claude loaded an invocation-only settings file with MyTerm's current managed hooks, an observer that recorded selected hook metadata, and a Bash ask rule. The standard CLI provided both dialogs.

| Action | Native hooks observed | MyTerm evidence |
| --- | --- | --- |
| Cancel an `AskUserQuestion` with Escape | `PreToolUse`, `PermissionRequest`, then a `permission_prompt` notification. The composer returned without a completion event before the next prompt. | The notification history recorded `awaitingInput` and had no new completion entry. |
| Answer a second question with Alpha | The same opening sequence, then `PostToolUse`, `PostToolBatch` and `Stop`. | The app displayed a finished indicator and the history acquired a `finished` entry. |
| Select No for the ordinary Bash permission dialog | `PreToolUse`, `PermissionRequest` and a `permission_prompt` notification. The composer returned with “Interrupted” and no completion event before exit. | The history contained an `awaitingInput` entry for the permission prompt. |
| Exit through `/exit` | `SessionEnd`. | The Claude terminal returned to the shell. |

`PermissionDenied` is documented for auto-mode classifier denials. It excludes a person rejecting the permission dialog, which matches this capture. The earlier feasibility run used an early-access `turn.complete` observer on Claude Code 2.1.325. Its behavior and availability on 2.1.331 still need validation if MyTerm adopts it. [Claude Code hooks reference](https://code.claude.com/docs/en/hooks#permissiondenied) · [Prior native-source prototype](https://github.com/GordonBeeming/myterm/issues/185#issuecomment-6904205471)

## Codex 0.170.0

Two interactive Plan-mode runs opened real blocking `request_user_input` dialogs. While the first dialog was pending, the terminal title said “Action Required” and the corresponding MyTerm Session Inbox row had no “Needs reply” label. Answering Alpha returned Codex to the composer and produced a `finished` entry in MyTerm. Escaping the second dialog also returned to the composer. The Codex tab's notification history contained only the completion from the answered turn.

The approval runner rejected the broad hook-trust action because it could enable unrelated hooks. The test continued with existing trusted hooks, so it confirms the app symptoms and leaves the native `PreToolUse` / `PostToolUse` / `Interrupt` observer path unverified on 0.170.0. The earlier observer capture covers 0.160.0.

## Integration decision

An opt-in, version-gated Claude observer could report these outcomes if native compatibility can be established. That path needs an installation and refresh design, tests on each supported CLI version, and a way to indicate when the observer is unavailable. Deferring the Claude portion keeps the integration on documented hooks and leaves these cancellation and rejection cases unsupported until a suitable event exists. Codex can be integrated independently after verifying the native event identities on the supported version.

This checkpoint covers five interactive scenarios and a clean Claude exit. Production integration, forced exits, concurrent requests, detached recovery, hook refresh and other platforms remain open. The [agent activity repair](https://github.com/GordonBeeming/myterm/issues/185) remains the acceptance ticket. Window captures and the local observer log are in the private temporary run directory.
