# MyTerm

## Preserve prototypes and work in progress

Prototypes, failed experiments, research, fixtures and useful evidence are project work. Include them in an authorized commit and PR even when their implementation is unfinished or their decision ticket remains open. Label their status and limitations clearly.

- Before committing or handing off, inspect tracked changes, untracked files and ignored locations that may contain unique work. Account for every item; build caches and reproducible binaries can stay excluded.
- When asked to commit the worktree or checkpoint progress, include all relevant WIP, not only the last ticket's files. If work needs separate commits, preserve it in those commits within the authorized scope.
- Check source, evidence, screenshots and logs for secrets, credentials and client data before staging. Sanitize publishable copies and report sensitive material withheld from Git; never publish it merely to make the tree clean.
- Before continuing in a fresh worktree, ending a checkpoint, or removing an old worktree, verify that each prototype and its required sources, fixtures and evidence are committed and pushed, or identify exactly what remains and where it is preserved. An issue comment, local artifact link or merged PR does not prove that untracked files were saved.
- Preserve historical or conflicting WIP as a labelled snapshot with its source worktree and file hashes; do not overwrite newer decisions with an older copy. Verify duplicate content against the committed copy before treating it as already preserved.
- Never delete, reset, clean, stash away or abandon unique WIP as a substitute for preserving it. Keep the original worktree intact until preservation is verified. Report missing or unrecoverable work explicitly; do not claim that a clean checkout proves nothing was lost.

Existing commit/push authorization, session worktree boundaries, signing, independent review and sensitive-data rules still apply. If preservation needs an action outside that authorization, identify the unsaved files and request the specific authorization before leaving them behind.

## Agent skills

### Issue tracker

Before creating, claiming or resolving work, read [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md). Use GitHub Issues in `GordonBeeming/myterm`; the existing MyTerm next map and its canonical URL are recorded there.

### Triage labels

When triaging incoming issues, use the role mapping in [docs/agents/triage-labels.md](docs/agents/triage-labels.md). Wayfinder decisions use only their `wayfinder:` labels.

### Domain docs

Before exploring the codebase, read [docs/agents/domain.md](docs/agents/domain.md). This repo uses one root `GLOSSARY.md` and `docs/adr/` for architectural decisions.
