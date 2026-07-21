# MyTerm

## Register

product

## Users

MyTerm is built first for Gordon, who works across many software repositories and keeps a large number of long-lived terminal sessions open. He moves between workspaces by title, uses a browser beside his terminal work, and expects the app to stay out of his way during focused development.

## Product Purpose

MyTerm is a fast, dependable macOS workspace for terminals and browser tabs. It keeps workspace navigation simple, supports horizontal and vertical terminal splits, restores the working layout after a restart, and remains responsive with dozens of live sessions. Browser tabs also keep their website data, so signing in does not become a daily ritual.

The first release succeeds when it can replace Gordon's daily cmux workflow without bringing across cmux's unrelated features or instability.

## Brand Personality

Native, quiet, dependable. The interface should feel dense without becoming cramped, and familiar without looking like a generic web dashboard.

## Anti-references

- Do not copy cmux's notifications, agent status, colored workspace metadata, or other features outside the requested workflow.
- Do not use decorative terminal chrome, novelty controls, or motion that interrupts focused work.
- Do not build terminal rendering on web technology when a native implementation is available.

## Design Principles

- Make workspaces scannable by title alone.
- Keep sessions alive independently of which workspace or tab is visible.
- Give every frequent action a clear keyboard path and a visible interface path.
- Prefer native macOS behavior for windows, focus, menus, tabs, accessibility, and appearance.
- Treat responsiveness under many live sessions as product behavior, not a later optimization.
- Make browser-data boundaries explicit. Gordon can share website sessions across the app, isolate them by workspace, or tie them to a project folder.

## Browser sessions and privacy

The browser-data setting applies when a new browser tab is created. Existing tabs keep the profile they already use, which avoids surprising sign-outs when the setting changes.

- **Across all workspaces** uses one cookie and website-data profile for the app.
- **Per workspace** keeps each workspace separate and is the default.
- **Per project folder** shares website data between browser tabs working from the same Git repository or folder.

WebKit stores cookies and local website data on disk for each profile. MyTerm never stores passkeys. It passes each request to macOS, where the user's chosen credential provider, such as Apple Passwords or 1Password, handles it. Arbitrary-website passkeys also require Apple's managed browser entitlement in the signed build; the Settings window shows whether that capability is present.

The main app ships with WebKit only, keeping the download and runtime footprint light. Chromium can arrive later as an optional, separately signed engine package rather than increasing the size and process count for everyone.

## Accessibility & Inclusion

Support full keyboard operation, visible focus, VoiceOver labels, sufficient contrast, and reduced motion. Follow the system light or dark appearance and never rely on color alone to communicate selection or state.
