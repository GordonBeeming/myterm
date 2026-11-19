# MyTerm WIP checkpoint

This checkpoint preserves the remaining prototypes and research from the active worktree, plus unique uncommitted files recovered from older MyTerm worktrees. It records unfinished work; it does not resolve their open tickets or make their candidate implementations production-ready. Original worktrees are untouched.

## Current worktree sources

| Sources | Scope / tracker |
| --- | --- |
| `script/agent-reporting-prototype/` | Native signal and adapter experiment; [reporting repair](https://github.com/GordonBeeming/myterm/issues/185) remains open. |
| `script/inventory-prototype/` | Inventory model, native lifecycle probes and retained captures; [inventory validation](https://github.com/GordonBeeming/myterm/issues/165) remains open. |
| `script/browser-routing-probe/`, `docs/research/myterm-browser-routing/` | Native HTTP CONNECT experiment demonstrates the client-local bypass; [browser routing validation](https://github.com/GordonBeeming/myterm/issues/160) remains open. |
| `script/layout-prototype/` | Accepted layout reference model; [production synchronization](https://github.com/GordonBeeming/myterm/issues/182) remains open. |
| `script/macos-service-probe/` | Disposable service/key-access feasibility sources; [production lifecycle acceptance](https://github.com/GordonBeeming/myterm/issues/173) remains open. |
| `script/relay-lifecycle-prototype/` | Accepted in-memory opt-out/inactivity model; [relay implementation](https://github.com/GordonBeeming/myterm/issues/152) remains open. |
| `script/relay-move-prototype/` | Accepted account-move model; [production moves](https://github.com/GordonBeeming/myterm/issues/179) remain open. |
| `script/trust-refresh-prototype/` | Disposable native TLS refresh experiment; [production trust/channel acceptance](https://github.com/GordonBeeming/myterm/issues/178) remains open. |

Some retained READMEs describe their capture-time state as local or uncommitted. This checkpoint publishes those sources and evidence without changing the historical native/GUI observations, decisions or limitations. Their recorded test counts apply to their named captures. Fresh checkpoint checks are recorded separately.

## Recovered from older worktrees

The read-only audit inspected all 23 registered MyTerm worktrees, including older worktrees under the home Codex directory. All 23 directories exist. The Developer worktree directory inventory was also checked. Previously deleted/unregistered worktrees and other repositories are outside this audit; this cannot prove that nothing was lost historically.

- The Rust terminal-state options research note from `20261107-jaunty-wren` is preserved at `docs/research/myterm-rust-terminal-state-options.md`. It is historical source review, preceding the measured feasibility experiment.
- The edited glossary from `20261107-crisp-marten` is preserved as `20261107-crisp-marten/GLOSSARY.md.txt`, with its diff. It contains older ownership assumptions, so it is not applied to the current glossary.
- The unfinished Companion test from detached worktree `3dc0/20261004-curious-tern` is preserved as `3dc0-20261004-curious-tern/TerminalExperienceTests.swift.txt`, with its diff. It is not added to the active test target.
- The remaining local map from `20261107-rusty-stitchbird` is preserved as `20261107-rusty-stitchbird/map.md.txt`. GitHub remains the canonical tracker. Seventeen other planning/prototype files in that worktree match committed archive files byte-for-byte; `manifest.json` records their hashes and committed paths.

`manifest.json` records exact original paths and recovered-file hashes. Two Finder metadata files were excluded. Ignored paths were also inventoried: build/dependency caches, editor state, shared-skill links, generated test reports and machine-local configuration remain excluded. Local configuration is not a prototype and may contain sensitive machine-specific settings.

The source worktrees still contain their original unsaved files. The manifest provides a verified committed copy; it does not authorize cleaning those worktrees. Existing committed branches and merged PRs were not modified or reimplemented here.

## Safety and repeatability

Prototype GUI drivers, native agent probes and service installers remain opt-in. The checkpoint checks use deterministic local fixtures, isolated temporary build/output directories and headless native probes. No live model turns, startup registration, production installs, credential changes or deployments are part of those checks. The native service unit tests query only a deliberately absent disposable Keychain item.

The browser result remains a failed candidate for the localhost routing requirement even when every fixture load completes. A successful command is not a claim that the redesigned browser contract is met.

Fresh checkpoint counts and raw summaries are in `checks.json` and the adjacent result files. Independent review and its exact scope are retained in `independent-review.json`. The source and generated diff of each recovered snapshot are hashed in `manifest.json`. Incidental local AddressBook paths in two logs were redacted; their private originals remain outside Git, with before/after hashes in the manifest.
