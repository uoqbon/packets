# Board providers

Pull requests always live on GitHub, so every provider needs the GitHub CLI (`gh`) signed in with access to the repository. The provider only decides where the board lives.

## github-project

A GitHub Project (v2), owned by a user or an organization, over the repository's issues.

- **Auth:** `gh auth refresh -s project` (the `project` scope), plus `repo`.
- **Config:** `board.githubProject.owner` (`@me`, a user login or an org login) and `number` (from the project URL). `fields` maps the kit's names to the project's field names; change it if your project already uses other names.
- **Fields:** Status (single select, the seven statuses), Priority (single select P0-P3), Size (single select S, M, L), Wave (text), Packet (text), Target date (date). `board setup` creates the missing custom fields. It never touches the options of Status: add Backlog, Ready, In progress, In review, Ready to merge, Needs human and Done in the project settings.
- **Issues** carry the `packet` label (and `human-task` for human tasks), so a REST listing finds them with their open or closed state. The phase becomes the issue's milestone.
- **Dependencies** are mirrored as GitHub issue dependencies ("blocked by") where the repository has them; otherwise skipped with one warning. The Depends on line in the packet stays authoritative.
- **Epic:** an `**Epic:** #<n>` line in the phase's `plan.md` makes each packet a sub-issue of that issue.
- **Cost:** listing the project spends GraphQL points (about 100 per 100 items); every session on the account shares 5,000 an hour.

## github-issues

Labelled issues, for repositories without a project or a token without the `project` scope.

- **Auth:** `gh` with `repo`.
- **Labels:** `packet`, `human-task`, `needs-human`, `follow-up`; `status:backlog` … `status:done` (one per issue, the kit keeps it so); `priority:P0` … `P3`; `size:S|M|L`; `wave:<value>` (created on first use). Prefixes are configurable under `board.githubIssues`. `board setup` creates them without changing existing labels.
- **Phase** is the milestone; **Target** stays in the issue body.
- Saved searches make a usable board: `is:open label:packet label:status:ready`, `label:status:in-review`, `label:needs-human`.

## azure-boards

Work items in Azure Boards, while code and pull requests stay on GitHub. Install the [Azure Boards app for GitHub](https://learn.microsoft.com/azure/devops/boards/github/) on the repository so `Fixes AB#<id>` in a PR body links the work item and moves it on merge.

- **Auth:** `AZURE_DEVOPS_EXT_PAT` set to a personal access token with **Work Items (Read & write)**, or the Azure CLI signed in (`az login`; the script asks it for a token). The scripts call the REST API directly (api-version 7.1; comments 7.1-preview.4); no `az devops` extension is needed.
- **Config:** `organization` (`https://dev.azure.com/<org>`), `project`, `workItemType` (User Story, Product Backlog Item, Issue…), `humanWorkItemType`, optional `areaPath` and `iterationPath`, `priorityField`, optional `targetDateField`, and `statusMap`.
- **statusMap** maps each status to a State, plus a tag where the process has fewer states than the workflow. `board setup` checks that every mapped State exists on the work item types. Starting points:

  | Status | Agile (User Story) | Scrum (Product Backlog Item) | Basic (Issue) |
  | --- | --- | --- | --- |
  | Backlog | New | New | To Do |
  | Ready | New + `status:ready` | Approved | To Do + `status:ready` |
  | In progress | Active | Committed | Doing |
  | In review | Active + `status:in-review` | Committed + `status:in-review` | Doing + `status:in-review` |
  | Ready to merge | Resolved | Committed + `status:ready-to-merge` | Doing + `status:ready-to-merge` |
  | Needs human | Active + `status:needs-human` | Committed + `status:needs-human` | Doing + `status:needs-human` |
  | Done | Closed | Done | Done |

  A tag wins over the State when the kit reads a status back, so each tagged status must have a tag no other status uses.
- **Tags:** `packet`, `human-task`, `size:<S|M|L>`, `wave:<value>`, `phase:<slug>` and the status tags. Priority uses the Priority field (P0 = 1 … P3 = 4).
- **Descriptions** are written as Markdown (`markdown: true`, needs an organization with Markdown support for work item fields). With `markdown: false` the packet text goes in as preformatted HTML, and sync can no longer tell a board-side edit from its own, so it always rewrites.
- **Dependencies** become Predecessor links; the epic (`**Epic:** AB#<id>` in `plan.md`) becomes the parent.
- **Comments** (claims, briefs) are posted as Markdown comments and deleted through the comments API.
- **Untested against a live organization** in the kit's own tests; run `board setup` and a `sync -DryRun` first.

## local

A JSON board in `<git common dir>/packet-board.json`: every worktree of the clone shares it, nothing is committed, nobody else sees it. For trying the workflow end to end on one machine and for `tests/run-tests.ps1`. Pull requests still go to GitHub.
