# Session workflow acceptance

Read `docs/AGENT_WORKFLOWS.md` for intended behavior and limits. Use disposable development workspaces and harmless commands. Capture before/after screens on each platform being changed. A live check must resolve to the intended Mac/workspace/tab/session, not just a matching label.

## Inbox and navigation

Generate real waiting/working/completed events and verify attention ordering and stable session identity. Open a session, return to the inbox and tap that same row again; the detail must reopen. Create a workspace from the inbox and from a folder's plus control; the new workspace must open immediately, with its controls and first terminal available. Return and reselect it. Search/jump must reuse an existing tab without duplicating it or moving another device's focus. Disconnect the host and verify cached information is visibly offline.

After reading an agent completion, switch workspaces and restart the desktop UI. The restored snapshot must not create another unread inbox entry, a fresh completion timestamp, banner or push notification. Restore genuinely outstanding questions and agent identity; verify new live activity still produces the normal attention events.

## Drafts and shared catalog

Write a distinct draft for one terminal, dismiss/reopen Compose, terminate/relaunch the app and confirm the text restores only to that pairing/workspace/session. Use a separate disposable pairing if testing removal. Revoke no existing user pairing merely to obtain cleanup coverage. Check interrupted insertion restores as unconfirmed and never automatically replays; transport success is not proof that an agent accepted the prompt. Multiline insertion without bracketed paste must fail safely.

Create/edit a prompt on the Mac, receive it on the paired companion, change it there and see the Mac update. Test global/workspace scopes and command/prompt categories. Create two entries successively without closing the picker: both must survive. Select into Compose, review the destination, edit, and insert without Return. A lost mutation acknowledgement must not create duplicates. Older/offline host status must be explicit. Use model tests for capacity/scope edge cases rather than filling a user's catalog with junk.

## Browser context

Capture a real development page containing a recognizable URL, selection and visible feature. Inspect the screenshot preview and actual saved PNG: file signature, readable image, private file permissions and intended current page. Confirm the instruction remains editable and insertion adds no Return. A file path is not an agent image attachment; verify agent/file access separately if claiming successful consumption. On companion native and Mac-rendered modes, check the documented selection/frame differences. Screenshot paste requires terminal control and agent paste support; serialize it with clipboard and pair-link tests.

## Persistent terminal restart

Start a harmless identifiable long-running command in a disposable terminal and record its shell/helper identity and output. Quit only the MyTerm UI, leave the helper running, reopen the same development state and verify reattachment to the same process, current output and correct geometry. Startup commands must not be repeated. Separately test explicit terminal/workspace close stops its helper. Helper exit or machine reboot is a distinct restart/fallback case, never proof of uninterrupted PTY survival. Keep the Mac UI running during mobile checks because the helper does not own companion connectivity.

Include inline images and text immediately after them when checking checkpoint fidelity. Compare restored cursor position, cells, image stripes and Kitty placement metadata using the view's actual font metrics, viewport and backing scale. Test font/viewport changes while output is in flight. Older incompatible helpers must fail explicitly; never claim they recovered images that their emulator already discarded.

## Completion evidence

For every requested workflow, report pass/fail/skip with the actual surface and artifact. Retain useful `.xcresult` attachments, focused test logs and before/after images. Explain blocked physical checks and environment prerequisites; never convert an unrun check or fixture screenshot into a live pass. Avoid retaining secret QR/pair-link content or private page data in a shareable report.
