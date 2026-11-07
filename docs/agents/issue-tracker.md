# Issue tracker: GitHub

Issues and specs live in GitHub Issues in `GordonBeeming/myterm`. Use the `gh` CLI with that explicit repository target for issue operations.

## MyTerm next map

The canonical map is [MyTerm next architecture and implementation](https://github.com/GordonBeeming/myterm/issues/125). Its GitHub sub-issues hold the active questions, discussions, resolutions and blocking relationships.

The original local files are retained as historical snapshots in `docs/planning/myterm-next/local-source/`. The migration manifest maps their local identities to GitHub issues. Use the GitHub map for continuing work; see `docs/planning/myterm-next/README.md` for the archive and fresh-worktree entry point.

## Issue operations

- Create issues with `gh issue create --repo GordonBeeming/myterm --title <title> --body-file <file>`.
- Read with `gh issue view <number> --repo GordonBeeming/myterm --json number,title,body,state,labels,assignees,comments`.
- List with `gh issue list --repo GordonBeeming/myterm --state open --limit 100 --json number,title,labels,assignees` and relevant label filters. The default limit is 30; a full page is not proof of a complete result. For exhaustive reads, use `gh api --paginate 'repos/GordonBeeming/myterm/issues?state=open&per_page=100' --jq '.[] | select(.pull_request == null)'` with any required query filters, then read individual bodies when needed.
- Use a UTF-8 body file for multiline issue bodies and comments. Comment with `gh issue comment <number> --repo GordonBeeming/myterm --body-file <file>`.
- Apply labels with `gh issue edit <number> --repo GordonBeeming/myterm --add-label <label>`.
- Post the resolution comment before closing with `gh issue close <number> --repo GordonBeeming/myterm`.
- Refer to issues by linked title in human-facing text.

## Wayfinding operations

- The map is one issue labelled `wayfinder:map`. Each decision ticket is a native sub-issue, labelled only `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling` or `wayfinder:task`.
- Use native sub-issue relationships and native blocking dependencies. With the installed CLI, use `gh issue edit <parent> --repo GordonBeeming/myterm --add-sub-issue <child>` and `gh issue edit <child> --repo GordonBeeming/myterm --add-blocked-by <blocker>`. Verify relationships after writing them. If an operation is unavailable, check the installed CLI and GitHub API rather than silently dropping the relationship.
- The frontier consists of open, unassigned children with no open blockers, in map order. Enumerate all children with `gh api --paginate 'repos/GordonBeeming/myterm/issues/<map>/sub_issues?per_page=100'`. Inspect native dependency state; closed blockers do not prevent work.
- Claim a ticket before working it with `gh issue edit <number> --repo GordonBeeming/myterm --add-assignee @me`.
- Resolve by posting the answer as a comment, closing the ticket, then adding its linked title and a one-line gist to the map's Decisions so far.
- Keep detailed decisions in their tickets. The map indexes closed decisions; query its children for open work.
- Preserve this effort's Notes, including its explicit execution scope, testing requirements and source-control authorization rules.

## Pull requests as a triage surface

PRs as a request surface: no.
