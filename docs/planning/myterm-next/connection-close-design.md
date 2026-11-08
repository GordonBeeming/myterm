# Native connection and close design

The authority for this design is [Prototype mixed-server connection and close states](https://github.com/GordonBeeming/myterm/issues/157#issuecomment-6725574787). Gordon selected the pane-local arrangement and refined it through live review so sessions feel local.

## Normal workspace

Keep server names, identities, routes and connection explanations out of the normal terminal view. A small server/status icon provides a short hover hint on Mac and details or recovery actions on click/tap. Connecting, disconnected, reconnecting, failed and approval-required states use subtle, accessible indicators.

Preserve the last terminal frame during an interruption, distinguish it from live output and keep input unavailable until connected. Other panes remain usable. Never silently create a replacement session or move it to another server. Preserve client-local focus during remote edits; select a surviving pane when the focused item is deleted.

## Closing work

Keep the existing confirmation rule: an active foreground process requires confirmation, while an idle shell prompt closes immediately. Cancel preserves the terminal. After confirmation, the shared item disappears immediately from the workspace. Workspace closure applies the same protection to its affected running processes.

Persist close intent before acknowledging it locally, then synchronize and clean up runtime resources in the background. Ordinary closure does not open a pending-close sheet, show a pending-count badge or require the person to manage old commands. Optional activity/details distinguish local deletion, failed submission, relay acknowledgment, queue expiry and actual termination confirmation.

Retry delivery and reconcile automatically when connectivity returns, including after neither server nor relay accepted the initial operation and after the seven-day relay queue expires. Closing locally does not imply confirmed runtime termination. The completeness, freshness and authorization safeguards in [Choose shared workspace synchronization and migration](https://github.com/GordonBeeming/myterm/issues/131#issuecomment-6707936341) remain in force.

After server removal, retain an outcome-unknown historical diagnostic record without requiring a pending-notice dismissal. Removal still preserves local processes/data and does not grant new termination authority. Navigation and client app closure/restart preserve sessions under the existing architecture decision and are distinct from closing a shared item.

## Evidence and remaining validation

The [native SwiftUI prototype archive](prototypes/connection-close-native/README.md) contains sources, captures, a self-contained review and build instructions. Its outcomes are scripted; it has no production integration. Mac and iOS Simulator builds passed, and the prototype was inspected on Mac, iPhone and iPad. The existing foreground-process confirmation regression passed one test with zero failures; see the [recorded test follow-up](https://github.com/GordonBeeming/myterm/issues/157#issuecomment-6725628044).

[Validate replicated layout convergence and deferred termination](https://github.com/GordonBeeming/myterm/issues/156) owns durable local intent, automatic retry/reconciliation, truthful acknowledgment and process-state freshness during partitions. [Set the implementation sequence and release acceptance checks](https://github.com/GordonBeeming/myterm/issues/136) carries the native interaction and responsiveness acceptance requirements. Real protocol behavior, crash/restart, terminal fidelity and destructive reconciliation still require implementation and integration evidence.
