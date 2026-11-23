# Claude Code 2.1.331 lifecycle observer

Validated on 24 November 2026 AEST in the signed MyTerm development app on arm64 macOS 27.3. The launcher loaded the mod with `--plugin-dir` only when explicitly enabled and the CLI reported exactly 2.1.331. The same launcher rejected 2.1.330 in its version check. The [earlier live baseline](native-agent-activity-baseline.md) covers 2.1.331 with the mod disabled.

## What failed and what changed

The earlier observer received `turn.complete` after both question cancellation and manual Bash rejection, but its candidate withdrew the activity snapshot in both runs. The diagnostic Bash run showed that Claude aborted the `$.process.run` call in the abandoned `tool.call` callback. The prototype counted that as missing telemetry, which invalidated the capture when the next event arrived. [Claude Code mod hook reference](https://code.claude.com/docs/en/plugins/mods/reference#the-hook-function)

The [tested patch](claude-observer-2.1.331.patch) checks `next.signal.aborted` before writing back a tool result for the current main turn. If Claude has abandoned that tool event, the observer lets the matching native `turn.complete` clear the pending request. Results and errors still pass through to Claude. The patch reports a count of skipped abandoned tool results on the turn-completion event. [Claude Code turn events](https://code.claude.com/docs/en/plugins/mods/events#follow-a-turn)

## Live results

| Action in MyTerm | Native turn completion | Candidate state | Abandoned tool results |
| --- | --- | --- | ---: |
| Cancel a blocking question | `answer`, `isAborted=false` | Finished | 1 |
| Reject an ordinary Bash permission prompt | `answer`, `isAborted=false` | Finished | 1 |
| Answer a blocking question | `answer`, `isAborted=false` | Finished | 0 |
| Approve a one-shot Bash command | `answer`, `isAborted=false` | Finished | 0 |
| Interrupt an approved running command | `aborted`, `isAborted=true` | Ready | 1 |
| Exit Claude with `/exit` | `SessionEnd` | Exited | |

The five turns each preserved one turn identity and ended with zero pending requests and no observer errors. The question answer and Bash approval controls also retained matching start and completion call IDs. A replay of the captured events verified the state after each turn. The source-native diagnostic and screenshots are in the private temporary run directory.

To repeat, apply the patch with `patch -p1` from the earlier prototype directory (`script/agent-reporting-prototype`, linked from the [repair ticket](https://github.com/GordonBeeming/myterm/issues/185#issuecomment-6904205471)). Materialize that mod into a disposable directory with the prototype's observer substitutions and enable it only for the exact CLI version. Launch that invocation in the isolated development window and compare native events with the candidate snapshot while each dialog waits and after the action.

The development app still used its standard hook reporter. The tested observer wrote candidate snapshots to a private file. Production installation, reporter integration, health reporting, delayed callbacks from earlier turns, concurrent waits and detached recovery remain part of the [agent activity repair](https://github.com/GordonBeeming/myterm/issues/185). The probe still has no separate transition for approval of a long-running command before its tool result arrives.
