# MyTerm Remote

A companion iPadOS and iOS app that reaches this Mac's MyTerm workspaces, and drives its live
terminal sessions from an iPad or an iPhone.

Status: first release candidate. The Mac host, the wire protocol, the iPadOS and iOS app, and the
relay are built, run end to end, and are covered by unit tests, host tests over a real socket,
relay tests against the real Worker running locally, and UI tests that drive the app in the
Simulator against live shells. See "Trying the proof of concept" below for what works and what
does not.

## Purpose

MyTerm keeps long-lived terminal sessions alive across folders, workspaces, pane groups, and tabs.
Those sessions only exist on one Mac. When the user leaves the desk, the work stops being reachable,
even though the sessions keep running and the agents keep working.

MyTerm Remote makes the same workspaces reachable from an iPad or an iPhone, on the local network or
from anywhere. The user links a device once. After that, the device lists the same folders and
workspaces, marks the tabs whose agent needs attention, and opens any terminal tab as a live,
writable session.

The Mac stays the only place a process runs. The device is a window onto it.

## What this is not

- It is not a separate terminal. The device never spawns a shell and never holds a session of its own.
- It is not a sync service. There is no account, no cloud copy of the workspace tree, and no server
  that can read terminal content.
- It is not a copy of the Mac layout. Splits, dividers, and pane groups stay on the Mac.
- It is not an agent dashboard. The device shows the same attention dot the Mac shows, and the same
  backlog the Mac's bell lists, as a Latest tab it can read through. It does not grade, chart, or
  summarise what agents are doing.
- It is not a remote browser. Browser tabs appear in the list, but MyTerm does not mirror a WKWebView.
- It is not a second way to configure MyTerm. Settings stay on the Mac.

## The experience

### Linking a device

1. On the Mac, the user opens Settings, then Devices, and turns on **Allow my devices to reach this Mac**.
2. The user presses **Link a Device**. A sheet shows a QR code and a countdown.
3. On the iPad or iPhone, the user installs MyTerm Remote and scans the code.
4. The device names itself, the Mac lists it, and the sheet closes.

The code expires after 120 seconds and works once. Later connections need no code.

Linking happens on the local network. It is the one step that requires the two devices to be together,
and that is what makes the pairing trustworthy.

### Using a linked device

The device opens on the folder and workspace list, in the Mac's order, with the same colors and pins.
A workspace row carries a dot when any of its tabs needs attention, exactly as the Mac sidebar does.

Opening a workspace shows a tab strip along the top and one open tab filling the screen. Output
arrives as the Mac receives it. Typing sends keys to the same process. The Mac pane and the device
show one session, because there is only one session.

Leaving a tab detaches it. The session keeps running. Nothing about the Mac's layout changes.

### Coming back

The app reconnects when it returns to the foreground. It re-attaches to the tab the user was on and
redraws the current screen. A short absence should look like nothing happened.

## How a workspace looks on a device

The Mac's split layout exists because a large display can show four things at once. A phone shows one.
An iPad shows one comfortably. The device does not reproduce the split.

The projection flattens a workspace into one ordered list of tabs.

- The order follows `Workspace.orderedGroups`, then each group's own tab order. `Workspace.allTabs`
  already computes exactly this, so the flattening is one existing accessor.
- Pane groups, split orientations, and divider proportions never reach the device.
- The device shows the flat list as a tab strip along the top, and one open tab at a time, full screen.
- Two tabs can carry the same title. The device disambiguates with the working directory's last path
  component beneath the title.

Three consequences, all of which are acceptable:

- Splitting a pane on the Mac reorders the device's tab strip. That is correct, because the list
  follows the Mac's reading order.
- The device cannot express that two panes sit side by side. An iPad split view is a possible later
  addition, and it is not part of a first release.
- Closing a tab from the device closes it in its Mac pane group. If it was that group's last tab, the
  pane closes, exactly as it does on the Mac.

## An agent tab is a conversation, not a screen

A phone cannot usefully show a hundred-column terminal grid. Scaling the type until the Mac's whole
pane fits lands at about six points on a phone in portrait, which leaves the text at the edge of
legibility and most of the screen empty. That is not a layout problem to solve. It is the fixed
aspect ratio of a mirrored grid meeting a small display.

An agent tab does not have to be mirrored, because the agent is not really drawing a screen. It is
having a conversation, and it already keeps its own structured record of one.

Claude Code appends one JSON object per line to `~/.claude/projects/<slug>/<sessionID>.jsonl` while
a session runs. Every turn is separated, and every tool call already carries its name and its whole
input. The host reads that file and sends messages. Nothing parses a terminal.

### What decides which surface a tab opens

The tab's agent session does.

- A tab whose agent MyTerm can read opens the conversation.
- Every other tab opens the terminal, unchanged.
- The raw terminal stays one tap away inside the conversation. Anything the conversation cannot
  express is still reachable, and that escape is what makes a simplified view safe to show first.

### Finding the file

By session identifier alone, searching `~/.claude/projects/*/<sessionID>.jsonl`.

Rebuilding the agent's own directory name from the pane's working directory is not reliable: the
directory is fixed when the session starts and the pane's moves as the person works. The identifier
is a UUID, so a search by name is both simpler and more correct.

The identifier arrives as terminal bytes and is used to build a path, so it is checked again at the
point of use and refused unless it can only name a file.

### What the device is not sent

- **The session identifier.** A tab carries `hasAgentConversation`, a boolean. The device asks by
  tab and the host does the looking up. An identifier would be a key to something outside the tree
  the device was given.
- **Image bytes.** The device is told an image was there, which explains the gap and costs nothing.
- **Anything uncapped.** A transcript holds whole files and whole command outputs. Every block, every
  tool detail, and the backlog as a whole are cut against `RemoteAgentLimits` before they reach the
  wire, and the device says so rather than presenting a cut file as a whole one.

### Commands run in the agent's own interface

A person typing `/model` or `/clear` is not saying something to the agent, and the agent's record
agrees: it files the command as a turn wrapped in `<command-name>` markup, what it printed in
`<local-command-stdout>`, and before both a `<local-command-caveat>` telling itself not to answer.
Newer builds file the same markup as a `system` record with subtype `local_command`. The projection
turns the pair into one `localCommand` block carrying the name, the arguments, and the output with
its terminal styling stripped, and drops the caveat, which is the same words every time and is
addressed to the agent. The device shows it as a centred note, "Ran /model" with the output under
it, rather than as a message bubble.

### Switching the model

Each assistant turn in the record names the model that wrote it (`claude-opus-5`), and the
projection carries that on the turn as `model`. A turn the agent made up itself, such as the
rate-limit notice, is written with the placeholder `<synthetic>` and carries nothing. The
conversation's current model is the last turn that named one, so the label follows the tail with
no message of its own.

The device shows that label as a menu in the conversation's bar. `AgentModelCatalog`, shared by
host and device, holds the switches `/model` documents: the family aliases `fable`, `opus`,
`sonnet`, and `haiku`, and `fable[1m]`, `opus[1m]`, and `sonnet[1m]` for the million-token
window. Choosing one types `/model <alias>` through the same reply path as any other words. There
is no second way into the agent: the record then shows the command ran, and the label changes when
the next answer names the new model.

### Running the agent's commands

`/model` is one of a family. `AgentCommandCatalog`, shared by host and device, sorts Claude
Code's slash commands by what a phone can do with them. Every row was run against the installed
CLI (2.1.258) through a PTY and its transcript read afterwards, so the table says what actually
happens rather than what a menu promises.

**Runnable from the phone.** Offered in a sheet behind the "/" button beside the reply field, and
opened by typing "/" as the first character. Each ends as one line typed through the reply path,
gated as the composer is.

| Command | Group | Argument | What the phone expects afterwards |
|---|---|---|---|
| `/clear` | Session | none | A new session. The command is recorded in the new session's file; the old file never grows again. The phone shows "New session" and starts over. |
| `/rename <name>` | Session | text, required | "Session renamed to: …" in the transcript. |
| `/compact [instructions]` | Context | text, optional | "Compacted …" in the transcript, and a `compact_boundary` record before it. |
| `/context` | Context | none | The usage grid in the transcript, then the same figures as markdown, which is what the phone shows. |
| `/model <alias>` | Model | the model menu | "Set model to …" in the transcript; the bar's label follows the next answer. |
| `/effort <level>` | Model | low, medium, high, xhigh, max | "Set effort level to …" in the transcript. |
| `/usage` | Info | none | Nothing in the transcript: a dialog on the Mac's screen. The host reads it off the grid and the phone shows it as the command's output, with a Dismiss button. See below. |
| `/status` | Info | none | As `/usage`. |
| `/help` | Info | none | As `/usage`. |

**Commands whose answer is on the screen.** `/usage`, `/status` and `/help` draw a dialog and
write nothing, so the transcript can never show their answer. The host reads it the way it reads a
permission prompt, from the tab's grid (`AgentScreenCapture`):

1. The phone types the command as any reply. The catalog, not the connection, decides which
   lines get this treatment (`AgentCommandCatalog.screenCommand(typed:)`): the three runnable
   info commands, and not a bare picker, which draws a menu to operate rather than an answer.
2. After the Return the host waits for the screen to settle: 500 ms for the dialog to draw
   (measured at 300–500 ms against the CLI), then a look every 100 ms until two in a row agree
   and differ from the screen the Return went into, capped at 2 s. A screen that keeps changing
   has a spinner on it, not a dialog, and one that never moves on has drawn nothing yet.
3. The rows go to the phone in `agentScreen`, as a `localCommand` marked `isScreen`, with blank
   rows trimmed from either end and collapsed within, the shared margin removed, and the text
   capped like any block. The phone adds the row itself ("Ran /usage" over the rows in a
   fixed-width face) and swaps the "shown on your Mac" bar for one that offers **Dismiss**, with
   the terminal as the secondary action. An empty capture leaves the old bar in place.
4. Dismiss sends `dismissAgentScreen`, gated by the Mac's input switch like every keystroke. The
   host sends the Escape a permission deny sends, waits for the screen to settle again, and
   reports whether the dialog is still there, judged by how many of its rows remain so a figure
   that ticks does not read as the dialog having gone. The bar stays while it is.

What the three look like, captured from the CLI at 100 by 30, is in
`Tests/MyTermRemoteHostTests/AgentScreenFixtures.swift`. Each closed on a single Escape.
`/usage` is taller than a 30-row terminal: the CLI scrolls it, the banner is cut off the top, and a
"↓" in the corner says there is more, which the phone shows as it is. The terminal view has the
rest. The `/status` dialog names the session and the working directory; a device that has asked
for the tab and typed the command could already read both through the terminal view, so nothing
new crosses the wire that the tree keeps back.

**Interactive on the Mac only.** Not offered. Typed by hand, the phone warns that the command
opens on the Mac and offers the terminal view, or sends it anyway. `/model` and `/effort` with no
argument belong here, because without one they open the picker. The rest: `/cost` (the usage
dialog), `/resume`, `/rewind`, `/config`, `/permissions`, `/mcp`, `/skills`, `/plugin`,
`/memory`, `/doctor`, `/fast` (a confirmation dialog), and `/usage-credits` and `/login`, which
start a sign-in flow.

**Not applicable.** Not offered and not named: `/exit`, `/logout`, `/vim`, `/terminal-setup`,
`/init`, and any custom skill. A slash command the table does not know is sent as typed, and the
agent says what it is.

Two commands change the record itself, and the projection handles both:

- `/clear` starts a new session. On a real Mac the `SessionStart` hook reports the new identifier
  and `AppModel` stores it against the tab, so the host's watcher asks for the tab's current
  session on every poll rather than holding the one it was given. A changed identifier is a
  fresh backlog: the device's conversation is replaced, and its first row is the `/clear` that
  started it, shown as "New session".
- `/compact` writes a `compact_boundary` record and then the summary as a user turn flagged
  `isCompactSummary`. The summary is never shown as a message. A manual compaction is shown once,
  by its `/compact` row ("Compacted the conversation"); an automatic one, which has no command,
  is shown as a note ("Conversation compacted").

**Notices.** The agent stops and names the command that would get it going again, and the
phone offers that command in a banner above the reply field. The matcher table covers the usage
limit ("You've reached your … limit … /model"), high demand ("use /model to switch"), a full
context window ("Context limit reached … /compact"), usage credits, and a lost sign-in
("run /login"). A notice's button does what the catalog says its command does: the model list for
`/model`, one tap for `/compact`, and the terminal for a command that only works on the Mac.
The banner goes once anything that is not the person's has been recorded after it: a command, a
note, or an answer. Warnings the agent records for itself (`informational`, and
`model_refusal_fallback`, which says a model was swapped after a refusal) are shown as notes and
feed the same matcher.

### Following it

The file is append-only while a session runs, so following it means remembering an offset and taking
what arrived since. Three cases break that and each is handled:

- The file does not exist yet, which is normal for the first seconds of a session. Wait and ask again.
- The last line is half written. Stop the offset at the last newline and take the rest next time.
- The file got shorter, so it was replaced rather than appended to. Read it again from the start.

Reading happens off the main actor. A long session reaches tens of megabytes, and the host must not
stop answering a device while it parses one.

### Answering the agent

Not yet built. What is known about it is worth writing down, because the obvious approach is unsafe.

A keystroke written to the pane's TTY does answer a live permission prompt. That was proven against
a real Claude Code session driven through a PTY: `1` then Return granted the request and the tool ran.

**A hardcoded number must never be sent.** The option list is not stable. One run offered four
options, where `3` was "Yes, and switch to auto mode": it granted the request *and* turned off every
later prompt in that session. A device button labelled "Deny" wired to a fixed digit would have done
the opposite of deny, from a place where nobody could see the consequence.

Two rules follow.

- **Deny is Esc.** Verified: it cancels and nothing runs. It is position independent, so it holds
  whatever the menu contains.
- **Allow must match a label, never a position.** The option list is on screen and not in the
  transcript, so the host has to read the numbered lines from the grid it already serialises and send
  the digit for the label the person actually tapped. Where it cannot parse a coherent list it must
  offer no allow button at all and fall back to the terminal.

"Don't ask again" and "switch to auto mode" do not belong on a device. They change what the Mac will
do unattended, and a phone is the worst place to decide that.

## Scope

### In scope for the first release

- One Mac, several linked devices, iPad first.
- The flattened workspace tree: folders, workspaces, tabs, titles, colors, pins.
- Live attach to any terminal tab, with output and input.
- The agent attention dot, mirrored from the Mac.
- Pairing on the local network, a paired-device list, and revocation.
- Reach from the local network, and reach through the relay from anywhere.
- An iPad split view, sidebar beside terminal, wherever the width is regular.
- Renaming and closing a tab, and renaming, creating, and deleting a workspace, from the device.
  Each is its own message, and each is refused unless the Mac allows devices to type: changing a
  workspace reaches further than typing does, so it cannot be permitted while typing is not.
- Creating a terminal tab in any workspace, including one the Mac has not selected.

### Later

- Answering an agent from the device: a reply field, and permission buttons under the rules above.
- The same conversation projection for Codex, whose sessions live under `~/.codex/sessions`
  in a different shape.
- Selecting a workspace or tab on the Mac from the device.
- Push notification when an agent needs attention while the app is closed.
- Moving tabs between workspaces, and reordering either, from the device.

### Never

- Passkeys, browser cookies, or website data leaving the Mac.
- A relay that can read terminal bytes, tab titles, or workspace names.
- A second copy of the workspace state that the device can edit while offline.

## Architecture

### Package layout

MyTerm is a SwiftPM package that targets macOS only. Two changes open it to iOS.

- Add `.iOS(.v17)` to the package platforms. `MyTermCore` already imports only Foundation and
  CoreFoundation, so it compiles for iOS without change. `MyTermPlatform` and `MyTerm` import AppKit
  and stay on macOS, because the device app never links them.
- Add two targets:
  - `MyTermRemoteProtocol` — the wire format, the message types, the framing, and the end-to-end
    cryptography. It depends on `MyTermCore` and Foundation only. Both sides link it.
  - `MyTermRemoteHost` — the Mac listener, the relay client, the pairing store, and the attachment
    manager. It depends on `MyTermCore`, `MyTermPlatform`, and `MyTermRemoteProtocol`.

The device app is an Xcode application target, because SwiftPM cannot build an app bundle. Put it at
`apps/MyTermRemote/`, and generate the project from a checked-in `project.yml` with XcodeGen, so a
reviewer reads text rather than a project file.

The relay is a service, not part of this package. It gets its own repository. See below.

### Do not put the persisted model on the wire

`Workspace`, `Tab`, and `TerminalSession` are already `Codable`. It is tempting to send them directly.
Do not. The persisted format carries migrations, backups, and recovery rules that exist for disk, and
the wire format needs its own version number and its own compatibility window.

`MyTermRemoteProtocol` declares its own view types. A projection function in `MyTermRemoteHost` maps
the live model onto them, flattening the layout as described above. The projection drops what a device
must never receive, including `recentText`, browser data profile identifiers, and agent session
identifiers.

### The terminal engine contract

`TerminalProcessSession` is the only contract between the app and its terminal engine. Four additions
carry the whole feature. Each gets a default implementation in the existing extension, so test fakes
stay small.

```swift
/// Receives every byte the process writes, in arrival order, before the emulator consumes it.
func setOutputTap(_ tap: (@MainActor (ArraySlice<UInt8>) -> Void)?)

/// Sends bytes to the process as if the user typed them.
func sendInput(_ bytes: ArraySlice<UInt8>)

/// The current screen, as the escape sequences needed to reproduce it on an empty terminal.
func gridSnapshot() -> TerminalGridSnapshot

/// Holds the process grid at a fixed size, ignoring the Mac view. Needed only if fit mode ships.
func pinGrid(columns: Int, rows: Int)
func unpinGrid()
```

`SwiftTermTerminalSession` already overrides `dataReceived(slice:)`, so the output tap is one line in a
method that exists. `send(txt:)` already carries input. The grid snapshot is new work.

### Attaching, and what the device sees first

A device that attaches midway through a session needs the current screen, not the future stream.

Replay from a raw ring buffer is the obvious approach, and it is wrong for this product. The agents
this feature exists to watch draw with cursor movement, and Codex draws on the alternate screen.
Replaying old bytes reproduces a scrollback, not a screen.

The host answers an attach with a **grid snapshot**: the visible rows serialized as SGR runs, plus the
cursor position, the cursor visibility, the alternate-screen flag, and the active modes. The device
feeds the snapshot into an empty emulator and arrives at the same screen the Mac shows. Live bytes
follow.

The grid serializer is the one piece of genuinely new terminal work in this feature. It is testable in
isolation, as described under Testing.

A raw ring buffer is acceptable in the first milestone, to get the path working end to end. It must
not be what ships.

**Built and proven.** `TerminalGridSerializer` and `TerminalSGREncoder` live in `MyTermPlatform`, with
13 round-trip tests. The round trip holds for plain text, the 16 ANSI colors, 256 colors, true color,
every character style, colored blank runs, cursor position, the bottom-right cell, and double-width
characters. Deleting the SGR emission fails all 13, so the tests bite.

**The alternate screen needs one resync, in one case.** `Terminal.isCurrentBufferAlternate` is public,
so the serializer reads it and paints onto the matching buffer. Two tests pin down when that is enough
and when it is not:

- A device that was in sync **before** a full-screen program started needs nothing. `?1049l` restores
  each terminal's own saved normal buffer, and the device's copy is already correct.
- A device that **attaches while** the program is running has an empty normal buffer, because the
  snapshot painted the alternate screen. When the program exits, that emptiness is revealed.

The second case is the ordinary one for this feature: picking up an iPad while Codex is running. The
host must send a fresh snapshot when the active buffer changes, through the same `resync` path that
backpressure uses. `TerminalDelegate.bufferActivated(source:)` is the hook to drive it.

**Two pieces of state cannot be captured.** SwiftTerm keeps both internal with no public getter, so
the snapshot cannot carry them:

- **Auto-wrap.** The snapshot turns it off to paint and always turns it back on. A session that
  deliberately disabled auto-wrap gets it re-enabled on the device.
- **Cursor visibility.** `resetToInitialState()` deliberately preserves `cursorHidden` across `ESC c`,
  so a cursor hidden on the Mac stays visible on the device.

Neither is likely to matter in practice, and both need an upstream change to fix properly. Record them
rather than pretending the snapshot is complete.

### Backpressure

An agent can write megabytes in a second. A device on a mobile network cannot always keep up, and a
queue that grows leaves the device minutes behind the Mac while consuming memory on both sides.

Each attachment holds a bounded send queue, 512 KB. When output overruns the queue, the host discards
the queue, sends `resync`, and follows it with a fresh grid snapshot. The device clears its emulator
and redraws.

This is correct behavior for a mirror rather than a compromise. A user watching a build scroll wants
the current screen, not every frame of it.

### Grid size

This is separate from the layout flattening above, and it is still open.

One process has one window size. The Mac pane has a grid, and the device has its own comfortable grid.
Two answers exist.

- **Mirror.** The device receives the Mac pane's grid and scales it to fit the width. Nothing about the
  Mac changes. On an iPad a 120-column grid stays readable, which is one more reason to start there.
  On an iPhone it does not, without zoom and panning.
- **Fit this device.** The process resizes to the device's grid while the attachment lasts, and the Mac
  pane reflows to match. Detaching returns the pane to its view-driven size.

Recommendation: mirror only in the first release, and add fit alongside the iPhone, where it earns its
cost. Fit must always be explicit and per attachment. A grid that resizes because a phone woke up in a
pocket is a bug the user cannot diagnose.

### Wire protocol

One connection carries every session, multiplexed by identifier. The same protocol runs over the local
network and inside the relay tunnel.

A frame is a 4-byte big-endian length, a 1-byte type, and a payload.

| Type | Name | Payload |
| --- | --- | --- |
| `0x01` | control | JSON, versioned |
| `0x02` | output | 16-byte session identifier, then raw bytes |
| `0x03` | input | 16-byte session identifier, then raw bytes |

Terminal bytes never pass through JSON. Base64 on a keystroke path costs latency and size for nothing.

Control messages:

| Message | Direction | Purpose |
| --- | --- | --- |
| `hello` | device to host | Protocol version, device name, device key |
| `welcome` | host to device | Protocol version, host name, capability list |
| `tree` | host to device | The flattened workspace tree, with a revision number |
| `treeDelta` | host to device | Changes since a revision |
| `attach` | device to host | Tab identifier, size mode, device grid |
| `attached` | host to device | Session identifier, grid size. A snapshot frame follows |
| `detach` | device to host | Stop streaming this session |
| `resize` | device to host | New device grid, honored only in fit mode |
| `resync` | host to device | Clear the emulator. A fresh snapshot follows |
| `agentActivity` | host to device | Tab identifier and the reported activity |
| `intent` | device to host | A requested change to the tree. Later milestone |
| `error` | either | A code and a message |

The host is authoritative. A device never mutates its own copy of the tree. It sends an intent, the
host applies it through the same `AppModel` command the Mac menu uses, and the host broadcasts the
resulting delta. One code path serves both surfaces.

## Pairing and security

This feature gives a device a writable shell on the user's laptop, reachable from the public internet.
It is the highest-risk thing MyTerm could ship. The design below is the minimum, not a starting point
for discussion.

### Defaults

- The feature is off. No key exists, no port is open, and no relay registration exists until the user
  turns it on.
- The local listener binds only while the feature is on and at least one device is paired, or while the
  pairing sheet is open.
- The listener advertises `_myterm-remote._tcp` through Bonjour.

### Keys

- Turning the feature on creates a long-term host key pair in the Keychain, protected by the login
  keychain and marked non-extractable where the hardware allows it.
- Each device creates its own key pair on first launch and keeps it in the device keychain, gated by
  the device passcode.
- **Forget All Devices** deletes the host key, every paired record, and the relay registration. Existing
  devices cannot reconnect, and re-pairing is the only route back.

### Pairing exchange

1. The Mac shows a QR code carrying the Bonjour service name, the host public key fingerprint, and a
   128-bit one-time secret.
2. The device connects on the local network, and both sides complete TLS 1.3 with a custom verification
   block that pins the fingerprint the QR code carried.
3. The device proves knowledge of the one-time secret and presents its own public key.
4. The Mac records the device, its name, its key, and the date. It also hands over the relay rendezvous
   identifier, inside this authenticated channel.

The secret expires after 120 seconds and is accepted once. A failed attempt invalidates it. Later
connections authenticate with the two long-term keys and need no code.

### While a device is attached

- The Mac shows one quiet indicator that a device is attached, with the device name behind it. This is
  a security affordance, not status decoration, and it is the one place the product's "no status layer"
  rule yields. The indicator states a live remote-input path, which the user has a right to see at all
  times.
- **Pause Input From Devices** is one command. Output keeps flowing and input is refused. This is what a
  user reaches for when handing the iPad to someone.
- The app requires Face ID, Optic ID, or the device passcode before it reveals the workspace list.

### Boundaries

- MyTerm logs no terminal bytes, and no message payload, at any log level.
- The projection never sends `recentText`, agent session identifiers, or browser profile identifiers.
- Only an attached session streams. Attaching to a tab is an explicit act.
- A revoked device is disconnected immediately, not at its next connection.

### Sleep and power

None of this works while the Mac sleeps. Say so in Settings rather than letting the user discover it
from a spinner.

While at least one device is attached, the host holds a `ProcessInfo` activity with
`.idleSystemSleepDisabled`, and releases it when the last device detaches. macOS may still sleep on
battery. A setting controls the assertion, and it is on by default.

## The relay

The relay lets a device reach the Mac with no network setup, from anywhere. It is a separate service
with its own repository, its own deployment, and its own on-call reality.

### The rules it must obey

1. The relay must never be able to read terminal bytes, tab titles, or workspace names.
2. The local network path stays preferred, because it is faster.
3. The Mac must never need an inbound port, a static address, or NAT traversal.

### How it works

This is built. The relay is a Cloudflare Worker with one Durable Object per rendezvous, in `relay/`.

- Turning on **Reach this Mac through the relay** generates a random 128-bit **rendezvous
  identifier** and a random **host key**. The Mac registers the identifier with the relay over one
  outbound WebSocket, proving itself with the key. The relay stores the first key it sees for an
  identifier, so no other Mac can take it. There is no account, no email, and no hostname.
- The Mac keeps that control socket open, with a ping every thirty seconds, and reconnects with
  backoff when it drops. Every connection is outbound, so no port forwarding and no NAT traversal
  are required.
- A device receives the relay's address and the rendezvous identifier inside the pairing code, on
  the local network. The relay never distributes it.
- A device connects to the relay naming the identifier. The relay tells the Mac, the Mac opens a
  session socket, and the relay joins the two and forwards binary frames. It is a pipe and nothing
  more.
- Inside that pipe runs **the same TLS session with the same pre-shared key** a device uses on the
  local network: TLS 1.2 with an ECDHE pre-shared-key suite
  (`TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`). Each end bridges its socket to a loopback port:
  the device dials that port with TLS exactly as it dials a Mac, and the Mac connects the session
  to its own listener. Neither end has a second authentication path, and the relay carries
  ciphertext from the first byte. The ephemeral key exchange gives forward secrecy, so the bytes a
  relay recorded stay unreadable even to someone who later learns the token. The Noise handshake
  the earlier design called for is not needed, because this already gives the same guarantee with
  the key pairing established.
- Regenerating the token on the Mac also discards the rendezvous, so a device holding an old code
  cannot even find the Mac at the relay.

A test in `RelayEndToEndTests` records every byte the device sends to and receives from the relay
and asserts that the workspace name, the screen, the host name, the device name, the typed input,
and the token never appear in it, and that the first byte is a TLS handshake record.

### What the relay can still see

Ciphertext, frame sizes, and timing. It can infer that some Mac and some device are talking, when, and
how much. It cannot infer what about. State this plainly in Settings and in the privacy statement.
Claiming more than this is worse than claiming nothing.

### Choosing the path

The device tries the Mac's Bonjour name for four seconds, then its address for five, then the
relay. A session that starts on the relay does not migrate to the local network in the middle of an
attachment, because a mid-attachment transport change is not worth the failure modes it adds.

The device shows a quiet "Through the relay" line while the relay is the route, so a user can tell
a slow relay from a slow Mac. The Mac's Settings show the relay's state and how many devices are
connected through it.

### Hosting

One Durable Object per rendezvous identifier on Cloudflare Workers. `relay/README.md` has the
protocol and the deploy steps: `npm install`, `wrangler login`, `npm run deploy`. Put the Worker's
origin into **Settings → Devices → Relay address** on the Mac. The Worker does not yet use
WebSocket hibernation, so an idle registered Mac holds a Durable Object awake; that is the first
thing to change if the bill matters.

Real cost is bytes forwarded during use.

### Operational burden to accept

Uptime, a status page, an abuse path, rate limits per rendezvous identifier, a privacy statement, and
certificate rotation. This is a service with users, and it needs an owner. That is the price of the
no-setup experience, and it was chosen knowingly.

### Also offer a manual address

A manual address field costs almost nothing and serves the user on a corporate network that blocks
Bonjour, the user already running Tailscale, and the user who does not want to trust a relay at all.
Ship it beside the relay, not instead of it.

## Telling the user an agent needs attention

The attention dot is the reason to carry this app. Its delivery has a hard platform limit that the plan
must state rather than discover.

- **Foreground, connected.** The `agentActivity` message drives the same dot the Mac shows. A tab
  that is not on screen also gets a local banner, so a person reading one conversation hears about
  another. Built; see `REMOTE_COMPANION_NOTIFICATIONS.md`.
- **Recently backgrounded.** The app holds a background task so iOS keeps the process, and the
  socket, for roughly 30 seconds after it leaves the screen. During it, the same local banner is
  raised when a message arrives. This is a useful window, and it is not a general solution.
- **Closed, or backgrounded longer.** Only Apple Push Notification service wakes an app, and APNs needs a
  provider that holds a signing key.

### The Latest tab

The bell on the Mac lists the agents that finished, or asked a question, in a tab the user was not
looking at. The Mac also keeps what it has listed once the user has caught up, as read history, and
what an agent said in the tab the user was looking at, filed read from the start, so the record is
complete without the bell ringing for it. The history is capped at 200 entries, forgets the oldest
read entries first, and is saved beside the workspace state; what comes back after a relaunch comes
back read, because the agents it pointed at went with the processes.

The device shows that history as its second tab, **Latest**, with the unread count as a badge. The host
sends the Mac's history whole in a `notifications` message, read and unread, newest first, on connect
and again whenever it changes, the same way it sends the tree. Each entry carries the workspace and tab
titles, because a device keeps entries after the Mac has forgotten them, and by then the tab may be gone
from the tree.

The device keeps its own log, newest first, capped at 200 entries, and it persists between launches.
Each host snapshot is merged into it: an entry the device has not seen is new, and as read as the Mac
says, so a device that connects after the user caught up at the desk still sees what happened, marked
read; an entry the Mac still lists takes the Mac's current names and is read if either side has read
it; and an entry the Mac has forgotten stays in the list as read history. An entry is a tab and a
moment, so a tab that needs the user again is a new unread row rather than a resurrected old one.
Opening a row lands on the same screen the workspace list opens for that tab, and reads it. Rows can be
swiped read or unread, and the toolbar marks all as read.

Reading on the device changes nothing on the Mac. Whether a tab read on the phone should lose its dot on
the Mac is not yet decided, so for now the Mac is the only place that reads its own backlog, and a Mac
that still lists an entry unread cannot undo a read made on the device.

A Mac running a MyTerm from before this tab never sends the message at all, and the device shows an empty
inbox rather than waiting on it. A Mac from before the history sends only its unread backlog, without
read marks, and the device treats every entry it sends as unread, which is what they are.

Push is not in this plan. It becomes cheap later rather than expensive, because the relay already holds
a connection to the host and a relationship with the device. Adding a contentless push is then a feature
of an existing service, not a new service. Should it ship, the payload carries no terminal content, no
tab title, and no workspace name. The app fetches the detail from the Mac after it wakes.

## The device app

### iPad first

The first release targets iPad. This is not a smaller scope for its own sake. It removes the software
keyboard, the small grid, and the pan-and-zoom work from the critical path, and it lets the architecture
be judged on a device where a 120-column grid is readable. The iPhone follows once the protocol,
snapshot, and reconnection behavior are proven.

### Structure

Both devices use the same shape, because the layout is already flat:

1. Folders and workspaces, with attention dots.
2. A workspace: a tab strip along the top, one open tab filling the rest.
3. Latest: what agents did while the user was away, read through like an inbox.

Workspaces and Latest are the two tabs of a bottom tab bar. On iPad the workspace tab is a two-column
split view, and it supports Stage Manager and an external keyboard. On iPhone it is a navigation stack.
There is no pane interface on either, and that is the point.

### The terminal surface

SwiftTerm supports iOS 14 and later, and ships `iOSTerminalView`, an accessory view, and a SwiftUI
wrapper. The app uses the plain `TerminalView`, never the local-process variant, and feeds it with
`Terminal.feed(byteArray:)`. Input arrives through the terminal delegate and goes onto the wire.

Coalesce feeds on a display link rather than feeding per packet. A device rendering a fast scroll is a
battery and heat load.

### The keyboard

An iPad with a hardware keyboard needs Control and Option chords mapped through the same input path,
and little else. That is the first release.

Software keyboards need an accessory bar carrying Escape, Control, Tab, the four arrows, and a paste
control at minimum. Evaluate SwiftTerm's own accessory view first, and replace it only if it falls
short. This work lands with the iPhone.

### Appearance and accessibility

The app follows the system appearance, uses Dynamic Type in its chrome, respects reduced motion, and
labels every row for VoiceOver. The terminal grid itself is not usefully readable by VoiceOver. State
that limit rather than implying parity.

The app inherits the Mac's terminal font size and theme through the projection, so a workspace looks the
same on both surfaces.

### Browser tabs

A browser tab appears in the flat list with its title and address. Selecting it offers **Open in Safari**
and an in-app web view with its own data store. The device does not receive the Mac's cookies, and it
does not share the profile. The interface says so in one line.

## The Mac side

The Mac app gains one Settings section and one indicator. It gains nothing else.

**Settings → Devices** contains:

- The **Allow my devices to reach this Mac** switch, off by default.
- **Link a Device**, which presents the QR sheet.
- The paired-device list: name, kind, path in use, last seen, and Revoke.
- **Reach my Mac from anywhere**, the relay switch, with the manual address field beneath it.
- **Forget All Devices**.
- **Keep this Mac awake while a device is attached**, on by default.
- One line stating that a sleeping Mac is unreachable, and one line stating exactly what the relay can
  and cannot see.

**Pause Input From Devices** lives in the application menu.

## Persistence

Paired devices and the rendezvous identifier persist beside the workspace state, in the same per-channel
directory, in a separate `remote-devices.json` file. Keeping it separate means a workspace recovery never
touches a security record, and revoking a device never rewrites the workspace file.

Keys live in the Keychain, never in JSON.

No part of the remote feature writes into `workspace-state.json`.

## Milestones

Each milestone ends in something that builds, tests, and can be judged.

**M1 — Shared foundations.** Add iOS to the package platforms. Add `MyTermRemoteProtocol` with the
message types, the framing, the flattening projection, and codec tests. No transport and no interface.
*Partly done:* the package declares `.iOS(.v17)`, `MyTermCore` type-checks against the iOS SDK, and
`script/ios_core_typecheck.sh` guards it in CI. `MyTermRemoteProtocol` does not exist yet.

**M1a — The grid serializer, pulled forward from M6.** It was the only part of this plan with no
reference implementation, so it ran first, where a bad result would have cost one day instead of five
milestones. *Done.* The remaining work it identified is the buffer-change resync, which belongs with
backpressure in M6 rather than with the serializer.

**M2 — Tap the terminal.** Extend `TerminalProcessSession` with the output tap and input injection.
Implement both in `SwiftTermTerminalSession`. Prove them against the existing fake engine in tests.
Nothing is visible to a user.

**M3 — Local transport and pairing.** Build `MyTermRemoteHost`: the Bonjour listener, the pinned-key TLS
handshake, the one-time pairing exchange, the device store, and the Settings section. Verify with a
command-line test client rather than an app.
*Usable at:* a terminal client on the same network can pair and echo bytes.

**M4 — The iPad app appears.** Add the Xcode project, the connection, the workspace list, the flat tab
strip, and the attention dots. No terminal yet.
*Usable at:* the iPad shows the real workspaces and their dots.

**M5 — Live terminals.** Attach, stream, input, detach, and hardware keyboard chords. Ring-buffer replay
is acceptable here.
*Usable at:* the feature does what it exists to do, on the local network.

**M6 — Correct screens.** Replace replay with the grid serializer. Handle the alternate screen, the
cursor, and the active modes. Add backpressure and resync.
*Usable at:* Codex and vim look right, and a fast build does not fall behind.

**M7 — Reconnection and sleep.** Fast foreground reconnect, re-attach, the sleep assertion, and the
manual address field.
*Usable at:* the app survives a lift, a lock screen, and a network change.

**M8 — The relay.** The service, the rendezvous registration, the Noise IK tunnel, the path selection,
and the privacy statement. The service can be built in parallel from M3 onward, because it depends only
on the framing, not on the app.
*Usable at:* the iPad works from anywhere.

**M9 — The iPhone.** The accessory bar, the small-grid decision from above, and the navigation stack.

**M10 — Acting from the device.** Intents for new tab, close tab, select tab, rename, and new workspace,
each routed through the existing `AppModel` command.

M1 through M8 are the feature. M9 and M10 extend it.

## Trying the proof of concept

1. Build and run MyTerm on the Mac.
2. Open **Settings → Devices** and turn on **Allow my devices to reach this Mac**. The Mac listens on
   port 52130 unless something else holds it, in which case the status line shows the port it took.
3. Build and run the companion app on the iOS Simulator:

   ```
   xcodebuild -project apps/MyTermRemote/MyTermRemote.xcodeproj \
       -scheme MyTermRemote \
       -destination 'generic/platform=iOS Simulator' build
   ```

4. In the app, either pick the Mac under **Nearby** in **Add a Mac…** and enter the token, or enter
   `localhost`, the port, and the token. The simulator shares the Mac's network, so both work. A real
   device scans the code from **Link a Device…** instead, with the app's own scanner or the Camera app.

The workspace list, the tab list, and a live terminal should follow. The token is what authorizes the
device: it is the pre-shared key for the TLS handshake, so a wrong token cannot connect at all.

### What is built

- `MyTermRemoteProtocol` — framing, control messages, the flattened tree, the TLS-PSK transport, and
  `RemoteClient`. Shared by both platforms.
- `MyTermRemoteHost` — the listener, per-device connections, backpressure, and the resync path.
- `AppModel+RemoteHost` — the app answering the host with real workspaces and real sessions.
- Settings → Devices on the Mac.
- `apps/MyTermRemote` — the iPadOS and iOS app: pairing by scan, by Bonjour, or by address; a
  remembered list of Macs with tokens in the Keychain; the workspace list with the cook; a live
  terminal that fits the Mac's grid; browser tabs; rename, close, create and delete from the device;
  and reconnection with backoff when the connection drops or the app returns to the foreground.

The transport is TLS 1.2 with an ECDHE pre-shared-key suite
(`TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`), the key derived from the pairing token. The
pre-shared key is the authentication: completing the handshake proves the device holds the token,
so a device without it cannot connect at all, and nothing on the network can read terminal bytes.
The ephemeral ECDH gives forward secrecy, so a recorded session stays unreadable after the token is
known. TLS 1.3 is not used because the platform does not offer it with an external pre-shared key.
Both facts are proven by tests: one points a client with the wrong token at a live listener and
requires that it never receives a tree; another reads the negotiated version and suite off a live
connection.

### Verifying it by hand

`Tests/MyTermRemoteHostTests/RemoteHostDemo.swift` serves real terminal sessions without the Mac app.
It is skipped unless asked for:

```
MYTERM_REMOTE_DEMO=1 MYTERM_REMOTE_DEMO_SECONDS=400 \
    MYTERM_REMOTE_DEMO_URL_FILE=/tmp/demo-url.txt \
    swift test --filter RemoteHostDemo
```

It writes a `myterm-remote://connect?...` URL carrying the port and token. Open that URL on a device,
or pass the same values to the simulator as launch arguments:

```
xcrun simctl launch <device> com.gordonbeeming.myterm.remote \
    -remote.host localhost -remote.port <port> -remote.token demotoken \
    -remote.reconnectsOnLaunch YES -remote.openTab tab-0
```

### Trying it on a real iPhone or iPad

The device and the Mac must be on the same Wi-Fi network.

**1. Run MyTerm on the Mac.**

```
make install && open ~/Applications/myterm.app
```

**2. Turn the listener on.** Open Settings, then Devices, and switch on **Allow my devices to reach
this Mac**. The status line shows the port. Copy the pairing token.

**3. Find the Mac's address on the network.**

```
ipconfig getifaddr en0
```

**4. Sign the companion app.** Open `apps/MyTermRemote/MyTermRemote.xcodeproj` in Xcode.

- Xcode → Settings → Accounts, and add the Apple ID if it is not there. A free Apple ID works.
- Select the MyTermRemote target, then Signing & Capabilities, and choose a Team.
- Xcode registers the device and creates the profile the first time it builds.

The team is recorded in `project.yml` as well, so regenerating the project with `xcodegen generate`
keeps it. Change `DEVELOPMENT_TEAM` there for a different account.

**5. Build to the device.** Pick the iPhone or iPad in the destination menu and press Run. On the
device, trust the developer certificate under Settings → General → VPN & Device Management if iOS
asks.

**6. Connect.** Press **Scan Pairing Code** and point the device at the code from **Link a
Device…** on the Mac, or open **Add a Mac…**, pick the Mac under **Nearby**, and enter the token.
**iOS asks for permission to find devices on the local network. Allow it.** Refusing leaves the
connection failing, and the app says so in words rather than with a code.

### How a device finds its Mac again

A saved Mac keeps two ways of being reached, and the device tries them in order:

1. **By name.** The pairing code carries the Bonjour name the Mac advertises. A Mac whose address
   changed, which is what DHCP does across a week, is still found this way on the local network.
2. **By address.** The host and port from the code, or from the last successful connection. This is
   what works where there is no Bonjour to ask, and it is why the Mac listens on a fixed port.

A Mac found by name has its address recorded once it answers, so both routes stay usable.

### When the connection drops

The workspace screens stay where they are. A banner says the Mac was lost, the device tries again at
1, 2, 4, 8, 15 and 30 seconds, and stops with a **Retry** button after that. Returning to the
foreground tries at once, because iOS closes the socket of a suspended app and that is the common
case. An open terminal attaches again on its own once the Mac answers. **Leave** is the way out.

A failure before the first welcome is a refusal, not a loss, and it is reported in plain words on the
list of Macs: nothing listening, the wrong token, or a Mac that cannot be reached, each with what to
do about it.

### What the first release does not do

- The relay is not deployed by this repository. Deploying it, and owning it, is a decision: see
  the "Operational burden to accept" section.
- The tree is polled once a second rather than pushed as a delta.
- Pairing tokens are standing, not one-shot: a code stays valid until the token is regenerated on
  the Mac. The Mac's Settings say so.
- **The device never tells the host its size.** The device shrinks its type until the Mac's whole
  grid fits, down to a floor where it clips instead. This is the mirror-only decision from the grid
  size section above. A Mac pane wider than about a hundred columns is hard to read on a phone in
  portrait, and rotating the phone is the answer for now.
- The terminal grid is not readable by VoiceOver.

### The relay tests

`Tests/MyTermRemoteHostTests/RelayEndToEndTests.swift` starts the real Worker with `wrangler dev`
and pushes a Mac and a device through it: a device reaches the Mac with no address at all, a device
is told when the Mac is not on the relay, a wrong token still fails, the address is tried before the
relay, and the relay sees only ciphertext. They are skipped until the Worker's dependencies exist:

```
cd relay && npm install
swift test --filter RelayEndToEndTests
```

The Worker's own protocol tests run with `cd relay && npm test`.

### The whole flow on one machine

Everything can be exercised locally, relay included, with nothing deployed.

**Scripted.** With `relay/node_modules` present, `make ui-test` starts a local Worker, registers the
demo host with it, and adds a UI test in which the device is given an address nothing listens on,
so its only way in is the relay. The test checks the "Through the relay" line and types a command
that the shell on the Mac runs.

**By hand, with the real Mac app.**

```
cd relay && npm run dev                                  # the Worker on http://127.0.0.1:8787
defaults write com.gordonbeeming.myterm.dev remote.listenerEnabled -bool true
defaults write com.gordonbeeming.myterm.dev remote.relayURL -string http://127.0.0.1:8787
defaults write com.gordonbeeming.myterm.dev remote.relayEnabled -bool true
./run.sh                                                 # the development Mac app
```

Settings → Devices then shows the relay as connected. To make the Simulator use the relay rather
than the loopback address, give it an address nothing listens on:

```
xcrun simctl launch booted com.gordonbeeming.myterm.remote \
    -remote.host 127.0.0.1 -remote.port 1 \
    -remote.token "$(defaults read com.gordonbeeming.myterm.dev remote.token)" \
    -remote.relay http://127.0.0.1:8787 \
    -remote.rendezvous "$(defaults read com.gordonbeeming.myterm.dev remote.relayIdentifier)" \
    -remote.reconnectsOnLaunch YES
```

The device lists the Mac's real workspaces with "Through the relay" beneath them.

### The UI tests

`apps/MyTermRemote/Tests/MyTermRemoteUITests` drives the app the way a person does: first run,
adding a Mac by hand, a wrong token, opening a terminal and typing into a real shell, the browser
tab, the close confirmation, a refused change, and disconnecting. They need a live host, and
`script/ui_test.sh` supplies one by running `RemoteHostDemo`:

```
make ui-test                                  # iPhone 17 Pro
make ui-test SIMULATOR="iPad Pro 13-inch (M5)"
```

Screenshots of every step land in `dist/ui-shots`.

### Two pins that have to stay in sync

The iOS app cannot reach SwiftTerm through the local package: SwiftTerm is a dependency of
`MyTermPlatform`, which imports AppKit, and it is not re-exported as a product. The app therefore
declares SwiftTerm as its own package in `apps/MyTermRemote/project.yml`, pinned to the same exact
version as the root `Package.resolved`.

Changing SwiftTerm's version means changing it in both places. Nothing enforces that yet.

## Testing

The pieces that are hard to test are the pieces most likely to be wrong.

- **Codec.** Round-trip every control message and every frame type. Reject truncated frames, oversized
  lengths, and unknown types without crashing.
- **Flattening.** Assert that a nested split layout projects to the Mac's reading order, that a
  re-split reorders predictably, and that duplicate titles carry a disambiguating directory.
- **Grid serializer.** Feed known bytes into a headless SwiftTerm `Terminal`, serialize the grid, feed the
  serialized bytes into a second empty `Terminal`, and compare the two grids cell by cell. This is a
  property test, it is cheap, and it catches almost everything that matters.
- **Backpressure.** Drive a deliberately slow client and assert that memory stays bounded and that a
  `resync` is sent.
- **Pairing.** Cover an expired code, a reused code, a wrong fingerprint, an unknown device key, and a
  revoked device that is currently connected.
- **Relay tunnel.** Assert that a relay that records every byte it forwards learns no plaintext. Run the
  Noise handshake against a hostile relay that replays, reorders, and truncates.
- **Projection.** Assert that `recentText`, agent session identifiers, and browser profile identifiers
  never appear in a projected tree. Make this a test, not a review habit.
- **Host tap.** Use the existing fake engine to confirm that attaching, detaching, and revoking leave no
  retained closure on a session.

## Risks

- **Scope.** This roughly doubles the product surface of an app whose stated virtue is narrowness, and the
  relay adds a service to a product that had none. It is defensible only because it adds a surface rather
  than adding chrome to the Mac. Keep the Mac app unchanged apart from one Settings section and one
  indicator.
- **Security.** A remote writable shell reachable from the public internet deserves an external review
  before any build reaches a device the developer does not own. This is not optional.
- **Running a service.** The relay is the largest ongoing commitment in this plan. It has uptime, abuse,
  and privacy obligations that do not pause. Budget for it as a product, not as a deployment step.
- **The grid serializer.** It is the only part with no reference implementation to lean on. Schedule it as
  real work, and do not let M5's ring buffer become permanent.
- **iOS input maturity.** SwiftTerm's iOS text input has seen less use than its Mac path. Budget time for
  chords, composition, and paste. Starting on iPad limits the exposure.
- **Sleep.** The most common support question will be a Mac that slept. Answer it in the interface.

## Settled decisions

- Reach is the local network plus a hosted relay, with a manual address field beside them.
- The first release targets iPad. The iPhone follows in M9.
- The device flattens each workspace into one ordered tab list. No pane interface ships on either device.
- Push notification to a closed app is out of scope, and the relay makes it cheap to add later.

## Open decisions

1. **Grid size.** Mirror the Mac's grid and scale it, or resize the process to fit the device? The
   recommendation above is mirror-only for the first release, with fit arriving alongside the iPhone.
2. **Relay hosting.** Cloudflare Workers with Durable Objects, or a small instance running a forwarder?
3. **Distribution.** TestFlight for the developer's own devices, or the App Store? The App Store adds
   review, a privacy label, and a support surface, and the relay makes a privacy label mandatory reading.
4. **Relay ownership.** Does the relay live in this repository's organization, and who is on call for it?
