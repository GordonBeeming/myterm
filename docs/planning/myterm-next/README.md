# MyTerm next planning archive

The canonical tracker is [MyTerm next architecture and implementation](https://github.com/GordonBeeming/myterm/issues/125) on GitHub. Continue decision work there using wayfinder; the map's Notes preserve this effort's execution scope and regression, integration and performance-testing requirements.

## Continue from a fresh worktree

Read `AGENTS.md`, then `docs/agents/issue-tracker.md`, then open the linked map. Query its sub-issues for the first open, unassigned ticket with no open blockers. Claim it before working; query live state rather than relying on the archive's ordering or status.

## Current domain decisions

[Choose shared workspace synchronization and migration](https://github.com/GordonBeeming/myterm/issues/131) supersedes the archived server-owned workspace model and the workspace-ownership portion of the earlier runtime decision. Use the root [glossary](../../../GLOSSARY.md) for current terminology and the ticket's resolution for ownership, synchronization, session closure and migration policy. Detailed decisions remain in GitHub; the retained snapshots below are historical evidence.

## Retained evidence

- `migration.json` maps the original local identities to GitHub issues and records their source states, dependencies and SHA-256 hashes.
- `local-source/` holds byte-for-byte copies of every original planning file. The added `.txt` suffix identifies raw historical material; embedded paths refer to the original checkout layout. These files are an archive, not an active tracker.
- [The recovery prototype](prototypes/recovery-prototype.html) is a portable copy of the self-contained discussion artifact, with GitHub source links and a note distinguishing historical privacy questions from the later agreed boundary. Its behavior is unchanged; the original bytes remain in `local-source/`. It is a throwaway explanation, not an implementation of cryptography or account recovery.
- Research reports remain in `docs/research/`, with canonical issue links and source-code citations pinned to the investigated commit.

GitHub ticket bodies hold the original questions. Imported discussion history and resolution comments preserve their order and provenance; closed decisions remain closed. Native sub-issue relationships and blocking dependencies represent the map's graph. This migration preserves decisions and evidence; it does not implement or verify the redesigned application.
