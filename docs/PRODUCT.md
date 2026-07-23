# MyTerm

## Register

product

## Users

MyTerm is built first for Gordon, who works across many software repositories and keeps a large number of long-lived terminal sessions open. He moves between workspaces by title, uses a browser beside his terminal work, and expects the app to stay out of his way during focused development.

## Product Purpose

MyTerm is a fast, dependable macOS workspace for terminal and browser pane groups. Each group owns its tabs and selected tab, so a split does not force unrelated work into one workspace-wide tab strip. It restores the working layout and divider proportions after a restart, and remains responsive with dozens of live sessions. Browser tabs also keep their website data, so signing in does not become a daily ritual.

The first release succeeds when it can replace Gordon's daily cmux workflow without bringing across cmux's unrelated features or instability.

## Brand Personality

Native, quiet, dependable. The interface should feel dense without becoming cramped, and familiar without looking like a generic web dashboard.

## Anti-references

- Do not copy cmux's notifications, agent status, per-workspace status metadata, or other features outside the requested workflow. Folder colors are organizational, not status signals.
- Do not use decorative terminal chrome, novelty controls, or motion that interrupts focused work.
- Do not build terminal rendering on web technology when a native implementation is available.

## Design Principles

- Make workspaces scannable by title alone.
- Let collapsible, color-coded folders separate work and personal contexts without adding metadata to workspace rows.
- Keep sessions alive independently of which workspace or tab is visible.
- Keep tab selection local to the pane group that owns it, including Control-Tab navigation.
- Give every frequent action a clear keyboard path and a visible interface path.
- Prefer native macOS behavior for windows, focus, menus, tabs, accessibility, and appearance.
- Treat responsiveness under many live sessions as product behavior, not a later optimization.
- Let users reshape a workspace with native split dividers and tab drag-and-drop without restarting a session.
- Make browser-data boundaries explicit. Gordon can share website sessions across the app, isolate them by workspace, or tie them to a project folder.
- Keep browser launches attached to the terminal pane that requested them, regardless of which workspace is active when the request arrives.
- Preserve the previous persisted bytes before a one-way migration or lossy recovery writes repaired workspace state.

## Browser sessions and privacy

The browser-data setting applies when a new browser tab is created. Existing tabs keep the profile they already use, which avoids surprising sign-outs when the setting changes.

- **Across all workspaces** uses one cookie and website-data profile for the app.
- **Per workspace** keeps each workspace separate and is the default.
- **Per project folder** shares website data between browser tabs working from the same Git repository or folder.

WebKit stores cookies and local website data on disk for each profile. MyTerm never stores passkeys. It passes each request to macOS, where the user's chosen credential provider, such as Apple Passwords or 1Password, handles it. Arbitrary-website passkeys also require Apple's managed browser entitlement in the signed build and the user's permission. The Settings window shows that state and requests access only after the user asks it to.

The main app ships with WebKit only, keeping the download and runtime footprint light. Chromium can arrive later as an optional, separately signed engine package rather than increasing the size and process count for everyone.

Browser navigation stays compact and familiar: Back, Forward, Refresh, then Address. Common commands operate on the selected browser tab—reload, address focus, history, find, and page zoom—while terminal selection keeps the same zoom keys scoped to terminal font size. Reload From Origin and Stop Loading remain explicit Browser-menu commands rather than taking over rename or cancel shortcuts.

## Workspace persistence and recovery

The persisted model follows the visible hierarchy: workspace, split layout, pane groups, then local tabs. Split proportions and each group's selected tab restore with the workspace. A v1 migration preserves the exact legacy bytes in an adjacent backup before its first v2 write. If decoding retains usable state but drops malformed elements, MyTerm preserves the original bytes in a separate adjacent recovery backup before saving the repaired snapshot.

## Accessibility & Inclusion

Support full keyboard operation, visible focus, VoiceOver labels, sufficient contrast, and reduced motion. Follow the system light or dark appearance and never rely on color alone to communicate selection or state.
