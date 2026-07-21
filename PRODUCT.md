# MyTerm

## Register

product

## Users

MyTerm is built first for Gordon, who works across many software repositories and keeps a large number of long-lived terminal sessions open. He moves between workspaces by title, uses a browser beside his terminal work, and expects the app to stay out of his way during focused development.

## Product Purpose

MyTerm is a fast, dependable macOS workspace for terminals and browser tabs. It keeps workspace navigation simple, supports horizontal and vertical terminal splits, restores the working layout after a restart, and remains responsive with dozens of live sessions.

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

## Accessibility & Inclusion

Support full keyboard operation, visible focus, VoiceOver labels, sufficient contrast, and reduced motion. Follow the system light or dark appearance and never rely on color alone to communicate selection or state.
