---
name: MyTerm
description: A dense, keyboard-first macOS workspace for terminals and browser tabs, drawn in the Graphite direction.
spacing:
  xs: "4px"
  sm: "6px"
  md: "8px"
  lg: "12px"
  sidebar: "240px"
radius:
  chip: "7px"
  control: "8px"
  field: "10px"
  pane: "10px"
  card: "12px"
  popover: "12px"
components:
  tab-row:
    height: "38px"
    padding: "5px 8px"
  tab:
    height: "28px"
    min-width: "110px"
    max-width: "220px"
  sidebar:
    width: "280px"
  notifications:
    width: "380px"
---

# Design System: MyTerm

## Overview

**Creative North Star: "The Graphite Workbench"**

MyTerm is a dense, keyboard-first workbench where the terminal and the page dominate. It now has a visual system of its own instead of stock macOS chrome: a dark neutral ground with a light counterpart, one accent, rounded containers, hairline borders, and Geist for interface text. The hierarchy comes from tone and structure, so chrome stays quiet while work is happening.

The app stays deliberately narrow in scope. It should never resemble an agent dashboard, a novelty terminal, or a web app wrapped in desktop chrome.

**Key Characteristics:**

- One semantic token set with light and dark values, and a single accent
- Compact, readable density
- Large uninterrupted terminal and browser surfaces
- Clear focus and keyboard paths
- Native behavior where macOS owns it: text fields, menus, popovers, splitters, and the Settings scene
- No ornamental status or motion

## Colors

Every color a view uses comes from the `Theme` tokens in MyTermUI. Each token has a dark and a light value and resolves from the active appearance. Terminal colors belong to the terminal profile and rendered content, not to the surrounding chrome.

| Token | Dark | Light |
| --- | --- | --- |
| `windowGround` | #0D0E10 | #F6F6F7 |
| `sidebarGround` | #121316 | #EEEEF0 |
| `paneGround` | #0A0B0C | #FFFFFF |
| `paneHeader` | #111215 | #F7F7F8 |
| `surface` | #15171A | #FFFFFF |
| `surfaceRaised` | #1A1C20 | #FFFFFF |
| `controlFill` | white 6% | black 5% |
| `selectedFill` | white 7.5% | black 7% |
| `hoverFill` | white 4.5% | black 4% |
| `hairline` | white 6% | black 8% |
| `hairlineStrong` | white 10% | black 12% |
| `textStrong` | #F1F2F4 | #0B0C0E |
| `textPrimary` | #E6E8EB | #17181B |
| `textSecondary` | #9CA2AB | #5B616B |
| `textTertiary` | #7F8590 | #737983 |
| `textDisabled` | #4B5058 | #B2B6BD |
| `accent` | #8EA2FF | #4257D8 |
| `danger` | #FF9C9C | #C2383A |
| `success` | #6FD3A0 | #1F8F5A |

There is one accent. Folder and workspace colors are separate: they stay the user's ten named colors and tint only the folder glyph and the workspace row.

**The Tokens Own the Palette Rule.** Views use tokens, never raw hex. A new color is a new token with both values, added to `Theme` before a view uses it.

## Typography

**Interface Font:** Geist
**Mono Font:** Geist Mono, for browser addresses, paths, and numeric captions
**Terminal Font:** the user's terminal font setting

**Character:** Interface text is plain and compact. Weights stay at 400, 500, and 600, so selection and hierarchy come from weight and tone, with few size changes. Both families are bundled in the app under the SIL Open Font License, with the license text shipped beside the font files. Where the fonts are not registered, as in unit tests and the Companion app, `Theme` falls back to the system font.

### Hierarchy

- **Title:** Geist 600 for folder names, section titles, and popover headers.
- **Body:** Geist 400 and 500 for workspace names, tab titles, and setting labels.
- **Caption:** Geist 12 pt in `textSecondary` for hints and inherited-value lines.
- **Mono:** Geist Mono for the host and path in the address capsule, file paths, and counts. The terminal surface itself uses the terminal font and nothing else.

**The Terminal Owns Its Font Rule.** Do not apply Geist Mono to terminal content or the terminal font to chrome. Do not spread Geist Mono into navigation or general controls to make the app look more technical.

## Elevation

MyTerm is flat. Tone and hairline borders separate surfaces, and shadows are kept for popovers.

- **Panes:** flush with the window and each other on `paneGround`, separated by a 1 pt hairline. No frame, no rounding, no glow.
- **Focus:** in a split workspace, the selected tab of the focused pane carries a 2 pt accent underline, like an editor's active tab. A single pane, or a pane shown full screen, carries no focus mark, since there is nothing else it could be.
- **Splitters:** keep their native behavior; the hairline sits inside a 6 pt drag target.
- **Popovers and menus:** the only place shadows appear, and only the ones macOS draws.

**The Working Surface Rule.** Terminal and browser content should remain visually dominant. Containers exist to frame the content.

## Components

### Workspace Sidebar

- **Width:** 220–480 pt, ideally 280 pt, on `sidebarGround`.
- **Folders:** A disclosure chevron, a folder glyph in the folder's own color, then the title in Geist 600. Folders collapse and accept dragged workspaces.
- **Workspaces:** Indented so the emoji column lines up with the folder title. A workspace with no emoji reserves no slot, and its title starts at the indent. The optional workspace color tints the row.
- **Selection:** `selectedFill` with a 7 pt radius.
- **Trailing slot:** The agent slot (below). The pin glyph, context menus, and VoiceOver labels stay; the label names the agent when its icon is shown.
- **Drag and drop:** Folder rows and the Unfiled header tint across their whole width and take the workspace at the bottom of that folder. A workspace row previews the drop instead: the rows slide to open the slot the drop would fill, so the order on screen is the order the drop commits. That slot decides everything at once, so a drop between rows can refile the workspace into the folder it lands in, reorder it there, and pin or unpin it to match the band, in one move. Folders reorder against each other the same way.
- **Actions:** Compact plus and minus icons at the bottom, with tooltips and accessibility labels. Renaming is an explicit command or context-menu action.

### Agent slot

One icon position on a tab or a sidebar row, shared by three things in this order:

1. **The state indicator**, while the agent is working, has finished, or has a question. Ready and exited show none. Each state has ten icons and the ten named colors to choose from, set once for the whole app under Settings › Agents › Indicators. The defaults are a stirring cook in gray for working, a tick that draws itself in, in blue, for finished, and a pulsing question bubble in purple for a question. Working icons move steadily, every question icon is animated to catch the eye, and finished icons stay still apart from the tick drawing in once. Reduce Motion stops every animation. The notification rows and the bell's tint use the same choices.
2. **The idle agent icon**, when the setting "Show the agent's icon when it's idle" is on and the agent is Claude Code or Codex. Claude is a six-ray asterisk in #D97757. Codex is a hexagon outline with a center dot in `textPrimary`. Both are generic shapes, not vendor logos, and carry the agent's name as their accessibility label.
3. **The normal icon**, which is the tab's terminal or globe glyph, or nothing on a sidebar row.

The setting defaults to off and applies to the whole app. An agent appears only where a hook reported a session, so a session started before the hooks were installed shows no icon.

### Tab Strip

- **Height:** A 38 pt strip holding 28 pt chips with a 7 pt radius.
- **Chips:** 110–220 pt wide, flexible. The selected chip takes `selectedFill`, `textStrong`, and weight 500. The close control shows on the selected chip and on hover.
- **Icon:** The agent slot, with the terminal or globe icon as its fallback.
- **Ownership:** Every pane group has its own strip and selected tab. There is no workspace-wide strip.
- **Overflow:** Horizontal scrolling keeps the local selected tab visible. The add-tab menu stays fixed.
- **Drag and drop:** A tab can reorder inside its strip, move to another group, or create a group by dropping on an edge.

### Terminal Pane

- **Surface:** SwiftTerm fills the pane edge to edge.
- **Splits:** Native draggable splitters preserve child proportions. Each pane has one quiet overflow menu for split and close actions.
- **Focus:** The AppKit first responder decides the active terminal. Only that terminal shows a caret at full opacity and only it receives pane commands; in a split workspace its selected tab also carries the focus underline.

### Browser Pane

- **Toolbar:** Back, Forward, and a Reload button that becomes Stop while a page loads, all 32 pt. Then the address capsule, a find button, and the pane actions menu.
- **Address capsule:** 34 pt tall with a 10 pt radius. The host is in `textStrong` and the path in `textSecondary`, both in Geist Mono. A lock glyph marks https, and a "local" chip marks anything else.
- **Browser-data chip:** Shown when the data profile is scoped to a folder, workspace, or project directory. It carries the folder glyph in the folder's color and the scope name.
- **Focus:** A focused address takes an accent border and the same 3 pt halo as a focused pane.
- **Suggestions:** A popover with "Go to" the typed address, followed by matching open tabs in the workspace, which switch to that tab. Arrow keys move, Return opens, Escape closes. There is nothing else in the list, and no button for opening the default browser.
- **Progress:** A 2 pt accent line under the capsule while a page loads.
- **Find:** A floating capsule with a 10 pt radius over the page, with the existing find behavior.
- **Surface:** WKWebView fills the remaining content area.
- **Behavior:** Browser and terminal panes can share horizontal and vertical split groups.
- **Commands:** Reload, address focus, history, find, and page zoom target only the selected browser tab. Reload From Origin and Stop Loading live in the Browser menu without overriding rename or cancel keys.

### Notifications

- **Entry point:** One bell in the primary toolbar. It stays in place when nothing is waiting, so the toolbar never reflows. It carries a tinted count chip only when there is a count to show.
- **List:** A 380 pt popover, newest first, showing five rows and a sliver of the sixth so a long backlog reads as "scroll for more" rather than a hard cutoff. Fewer than six entries show every row. The height comes from the row count and a row height that does not depend on which rows a lazy container has measured, so the list can never settle on a partial row.
- **Header and footer:** The header reads "Notifications", then how many are waiting, then Clear All. A footer line explains how rows clear.
- **Row:** The first line has a cook glyph and what the agent did, with the time at the end, and the time never truncates. The second line has the workspace emoji, the workspace, and the tab, truncated in the middle. Names are resolved from the live workspace, so renaming a tab renames the row. Rows take `hoverFill`.
- **States:** Each row draws the finished or question indicator chosen in Settings and says which in words, so the two never depend on icon or color alone.
- **Reading:** Clicking a row goes to its tab, which is also what clears it. Clear All reads every tab in the list.
- **Empty:** Say plainly that nothing is waiting. Do not hide the control.

### Settings

- **Scene:** The native macOS Settings window, separate from the workspace window, with a sidebar of sections: General, Terminal, Browser, Agents, Companion, and Permissions.
- **Cards:** Rows are grouped on `surface` cards with a 12 pt radius and hairline separators. Labels are Geist 500, and captions are 12 pt in `textSecondary`.
- **Scope:** A header shows the section title and a hint. Only Terminal and Browser hold settings a folder or workspace can override, so only they get the segmented switch for Global, the folder, and the workspace. General, Agents, Companion, and Permissions apply to the whole app.
- **Scoped rows:** An inherited row says where its value comes from and offers Override, and its control is dimmed. An overridden row says what it overrides and offers Reset. Sections that apply to the whole app are marked "whole app" and dimmed when a folder or workspace scope is selected.
- **Browser data:** One picker with four plain-language choices, ordered from widest to narrowest: Across all workspaces, Per MyTerm folder, Per workspace, and Per project directory. "Folder" always means a sidebar folder and "directory" always means a path on disk, so the two never read as the same thing.
- **Expectation:** Say that the choice affects new browser panes and that existing panes keep their current profile.
- **Agents:** Agent activity, agent notifications, and agent sessions are three sections in that order, followed by the idle-icon row, which shows both icons as a legend. The hook buttons live under activity, since the cook is what they were made for; name the file each button writes and say that only MyTerm's own hooks are added or removed. The sessions section holds two app-wide toggles, says that restoring rejoins the pane's last conversation with the agent's own resume command, says that naming a tab after a conversation takes the name the agent writes and gives way to a name the user typed, and points back at the hooks above rather than repeating them, because the hooks are what make both possible.
- **Companion and Permissions:** The same content and actions as before, as cards, with a status pill for each permission.
- **Passkeys:** Show whether the signed build has Apple's managed browser entitlement and browser access. Request access from a clear button, never on launch. State that MyTerm passes requests to macOS, does not store passkeys, and leaves the choice of credential provider to the user.

### App Icon

- **Shape:** A standalone macOS icon, not a copy of another terminal's mark.
- **Motif:** A terminal prompt combined with a branching signal that hints at projects, panes, and Xylem.
- **Palette:** Xylem slate neutrals with the cyan and teal accents. Keep enough contrast to read at Dock and Spotlight sizes.
- **Rule:** No product name, letters, traffic-light controls, or borrowed terminal-brand shapes inside the icon.

### Browser engine boundary

- **Built in:** WebKit is the only engine in the main app and remains the default.
- **Boundary:** The app asks a browser-session factory to create a session for a named data profile.
- **Later:** Chromium is a separate signed and notarized download with its own helper processes, not payload carried by every MyTerm install.
- **Security:** Keep library validation enabled and require the engine package to be signed by the same developer team as the host app.

### Commands

- **Visible path:** Toolbar, contextual menu, or local action button for every frequent task.
- **Keyboard path:** Native menu commands for workspace creation, terminal and browser tabs, splits, close, sidebar visibility, and the notifications backlog.
- **Contextual zoom:** Command-Minus and Command-Equals change browser page zoom when a browser is selected, or the active workspace's terminal font size when a terminal is selected. Command-0 resets browser page zoom.

### Persistence and Recovery

- **Hierarchy:** Persist workspaces as a split layout of pane groups, with each group owning its tabs and selected tab.
- **Split state:** Persist dragged divider proportions and restore them with the workspace.
- **Migration:** Before the first v2 write, atomically preserve the exact v1 file at a deterministic adjacent backup path.
- **Lossy recovery:** If malformed array elements must be discarded, preserve the original bytes in a separate adjacent recovery backup before committing repaired state.
- **Identity:** Keep already-unique workspace, group, tab, pane, split, terminal-session, and browser-session identifiers stable across migration and repair.
- **Agent tab names:** Name a tab after the agent conversation running in its pane, taken from the terminal title the agent already writes. Take a title only while an agent has reported itself in the pane, so a shell's title is never mistaken for a conversation name, and never over a title the user typed. Keep only a plain short name out of what arrives: the title is terminal bytes, which any program in the pane can write.
- **Agent notifications:** Derive the tab cook, the bell, and the banner from one inbox fed by the same hook event, so the three cannot disagree. Reaching the tab reads the entry, one tab holds one entry, and the latest report is what the entry says. Keep what the bell has listed as history in its own file beside the workspace state, read one row at a time so a bad row cannot lose the file, deduplicated, newest first, capped on load, and written only when it changes. It comes back read: the agents it pointed at went with the processes.
- **Agent sessions:** Persist the agent conversation a terminal pane was in, and re-enter it on the next launch with that agent's own resume command. Save only what an agent hook reports, keep the identifier out of the interface, and drop it when the pane is left at a shell prompt. Restore an agent only when its reported identifier is one its resume command accepts: a pane that opens on a resume error is worse than a pane that opens on a prompt.

## Do's and Don'ts

### Do:

- **Do** keep workspaces scannable by title alone.
- **Do** take every color, radius, and spacing value from `Theme`.
- **Do** use native macOS controls and behavior where the system owns them: text fields, menus, popovers, splitters, and focus.
- **Do** keep the tab strip at 38 pt and scroll it when tabs exceed the available width.
- **Do** preserve a large, uninterrupted content surface.
- **Do** provide both a visible route and a keyboard route for frequent actions.
- **Do** make visible focus and VoiceOver labels part of the component contract, including every icon-only control.

### Don't:

- **Don't** copy cmux's notifications, agent status, or other features outside the requested workflow. Per-workspace indicators are limited to the agent slot, and identity icons are opt-in. Restoring an agent session is persistence, not a status layer: it belongs in the pane's saved state and in Settings, never in extra workspace chrome.
- **Don't** use decorative terminal chrome, novelty controls, or motion that interrupts focused work.
- **Don't** build terminal rendering on web technology when a native implementation is available.
- **Don't** write raw hex or a one-off font in a view.
- **Don't** add a second accent, or shadows outside popovers and menus.
- **Don't** use vendor logos for agent icons.
- **Don't** let browser controls or navigation chrome compete with the active terminal or page.
