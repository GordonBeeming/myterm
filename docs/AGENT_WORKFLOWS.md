# Session workflows

## Find a session or work through the inbox

On the Mac, **Workspace → Jump to a Tab…** (`⌘P`) searches existing tab titles,
workspace names, folders and paths. An empty query puts attention first, followed by
recently visited tabs. Selecting a result reuses that tab.

**Workspace → Session Inbox…** opens the optional desktop inbox. The companion starts
with the selected Mac's inbox and offers a workspace view alongside it. Terminal sessions
stay in the list after being read; sessions needing attention rise to the top. A question
stays marked until the agent continues. Browser tabs appear in search, but not the inbox.

The companion inbox covers its selected Mac. Switch hosts to see another Mac's sessions.
Disconnected hosts show cached state explicitly. Navigation history is local to each app
process and is not synchronized between devices.

## Compose a reply

The companion's **Compose** editor can hold text while a terminal is view-only.
**Insert into terminal** inserts the text; **Insert + Enter** also sends Return.
Both require terminal control. Multiline insertion requires bracketed paste, so a page
selection or saved prompt cannot accidentally become several shell commands.

Drafts are stored locally by pairing, workspace and terminal identity. A relaunch restores
the text and changes any interrupted send to **unconfirmed**. Transport success does not
prove that the terminal displayed the text or that an agent accepted it. Check the terminal
before retrying an uncertain insertion; MyTerm never replays it automatically.

Persistent draft storage is bounded to 128 entries and 64 KiB of text per entry. When a
new draft cannot be persisted, Compose reports that it is only in memory. An oversized
edit keeps the previous saved text and reports the limit. Removing a pairing removes its
drafts. A fresh host snapshot prunes closed terminal drafts, while preserving in-flight
or unconfirmed insertions and drafts for other hosts.

## Reuse a prompt or command

On the Mac, open **Tabs → Saved Prompts and Commands…**. On the companion, use the saved
entries button in Compose. Prompts and commands have separate categories and can apply
to the whole Mac or one workspace.

The Mac owns the catalog. Paired companions receive it with workspace snapshots and can
create, edit or delete entries while connected. A saved entry has a stable identity, so
retrying a mutation after a lost acknowledgment updates that entry instead of creating a
duplicate. A confirmed creation rotates that identity before the next new entry.

Selecting an entry fills an editable draft. Review its text and destination before
inserting; desktop insertion does not add Return. The catalog is limited to 100 entries,
256 UTF-8 bytes per name, 64 KiB per text and 192 KiB of encoded catalog data. Older hosts
without catalog support and disconnected hosts show their status rather than accepting
unsynchronized edits.

## Bring browser context to a terminal

The Mac browser's **Capture browser context** action captures its URL, title, selected
text and visible screenshot. The review sheet lets you edit the instruction and select
an existing terminal in that workspace. The screenshot is saved as a private temporary
PNG, and an optional file reference is inserted with the text. The agent must read that
file; this is not an automatic image attachment. Capture files older than 24 hours are
removed on the next capture or app launch.

On the companion, the browser context action opens a review sheet. Native browsing captures
its current page and selected text. Mac-rendered browsing uses the last displayed frame
and reports that selection is unavailable. **Append context to Compose** appends text to
the chosen terminal's existing draft without sending it. Screenshot paste is a separate
action, requires an attached terminal with control, and uses the Mac clipboard and paste
shortcut. The agent must support pasted images.

Capture does not collect cookies or form values. Screenshots can still contain anything
visible on the page; inspect the preview before passing it to an agent.

## Quit without stopping terminal work

Each persistent terminal has a separate `MyTermSessionHost` process. It owns the PTY and
terminal checkpoint. MyTerm attaches through an authenticated, private local socket.
Quitting, closing the last app window or an app crash leaves that host running. Reopening
MyTerm reattaches to the existing shell, including output and agent activity produced
while the UI was closed. Startup and agent resume commands are not repeated on reattach.
A large scrollback restores a bounded tail into the reopened view, with a notice when older
lines were omitted; the helper retains its configured full history. Persistent viewports
are bounded to 1,024 columns/rows and 262,144 cells per buffer, with matching native/host
geometry and a notice if an unusually large viewport is limited.
Attachment runs off the UI thread; a connecting pane rejects input until ready.

Restoring agent activity reconstructs the session and outstanding questions without creating
another completion notification or marking already-read work as new. Retained inline images
and text after them restore using the native view's measured image geometry. Image sizes and
retained raster memory are bounded; older image stripes can be evicted to preserve a usable
checkpoint. A helper with an incompatible checkpoint protocol must be closed explicitly.

The app and helper verify each other's code-signing identities before exchanging terminal
state or input. Production uses matching Developer ID signatures and hardened runtime.
Stable development signing supports reconnecting after a rebuild; explicit ad-hoc dev builds
pin the exact matching executable and should close disposable panes before replacing it.

Closing a terminal tab or workspace explicitly stops its host while the app is running. That also applies when its
view has not been attached or a connection attempt fails. If the app crashes during an explicit close before the stop completes, a helper can remain
running without a listed pane. Startup does not automatically stop unlisted helpers.
The app bundles and signs the helper alongside its own executable. Keep the complete app bundle when moving or updating it.

New terminals run the helper from a private copy of its exact signed build under
`session-hosts/` in the app's support directory, not from inside the app bundle. macOS checks
a running helper against the file at its launch path, so a helper started from the bundle would
fail authentication once an update replaced that bundle, leaving its live terminal unattachable.
An updated app keeps attaching to terminals started by the previous build. Each launch removes
copies that no running process uses. Explicit ad-hoc development builds still run the helper in
place, because without a team identity it finds its controller through the surrounding app.

Quitting during a new terminal's first attachment can leave its shell running before the
initial command is sent. Check that command's terminal after reopening before retrying it.

A host reboot or an exited helper ends the original process. Saved output and supported
agent conversation recovery remain separate fallbacks; they cannot recover an in-flight
shell command. When saved output exists and a replacement host starts, MyTerm reports the
restart. Development and production use separate host namespaces.

The terminal helper does not host the companion relay connection or push notifications.
The Mac must remain awake and the MyTerm UI app must remain running for companion access
and event notifications, even though terminal processes can outlive that UI.
