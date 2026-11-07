# MyTerm next planning archive

The canonical tracker is [MyTerm next architecture and implementation](https://github.com/GordonBeeming/myterm/issues/125) on GitHub. Continue decision work there using wayfinder; the map's Notes preserve this effort's execution scope and regression, integration and performance-testing requirements.

## Continue from a fresh worktree

Read `AGENTS.md`, then `docs/agents/issue-tracker.md`, then open the linked map. Query its sub-issues for the first open, unassigned ticket with no open blockers. Claim it before working. At migration, the next ticket is [Choose hosted and self-hosted relay account operations](https://github.com/GordonBeeming/myterm/issues/134); query live state rather than assuming it remains available.

## Retained evidence

- `migration.json` maps the original local identities to GitHub issues and records their source states, dependencies and SHA-256 hashes.
- `local-source/` holds byte-for-byte copies of every original planning file. The added `.txt` suffix identifies raw historical material; embedded paths refer to the original checkout layout. These files are an archive, not an active tracker.
- [The recovery prototype](prototypes/recovery-prototype.html) is the original self-contained discussion artifact. It is a throwaway explanation, not an implementation of cryptography or account recovery.
- Research reports remain in `docs/research/`, with canonical issue links and source-code citations pinned to the investigated commit.

GitHub ticket bodies hold the original questions. Imported discussion history and resolution comments preserve their order and provenance; closed decisions remain closed. Native sub-issue relationships and blocking dependencies represent the map's graph. This migration preserves decisions and evidence; it does not implement or verify the redesigned application.
