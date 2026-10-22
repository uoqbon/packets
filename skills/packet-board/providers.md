# Board providers

Pull requests always live on GitHub, so every provider needs the GitHub CLI (`gh`) signed in with access to the repository. The provider only decides where the board lives.

## github-project

A GitHub Project (v2), owned by a user or an organization, over the repository's issues.

- **Auth:** `gh auth refresh -s project` (the `project` scope), plus `repo`.
- **Config:** `board.githubProject.owner` (`@me`, a user login or an org login) and `number` (from the project URL). `fields` maps the kit's names to the project's field names; change it if your project already uses other names.
- **Fields:** Status (single select, the seven statuses), Priority (single select P0-P3), Size (single select S, M, L), Wave (text), Packet (text), Target date (date). `board setup` creates the missing custom fields. It never touches the options of Status: add Backlog, Ready, In progress, In review, Ready to merge, Needs human and Done in the project settings.
- **Issues** carry the `packet` label (and `human-task` for human tasks), so a REST listing finds them with their open or closed state. The phase becomes the issue's milestone.
- **Dependencies** are mirrored as GitHub issue dependencies ("blocked by") where the repository has them; otherwise skipped with one warning. The Depends on line in the packet stays authoritative.
- **Root issue:** a root line in the phase's `plan.md` (`**Epic:** #<n>`, or `**Feature:**` or `**User Story:**`) makes each packet and human task a sub-issue of that issue. GitHub has no levels, so the tree is one deep, except that a human task with a `**Parent:** <packet ID>` line becomes a sub-issue of that packet's issue (both GitHub providers).
- **Moves:** an issue has one parent. Sync makes an issue with none a sub-issue of its place; one under another parent is named and left there, and `sync -Force` moves it (`replace_parent`). Sync reads that parent from the parent-issue endpoint; on a GitHub Enterprise Server without it, adding an issue that has a parent fails, as it did before.
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
- **Config:** `organization` (`https://dev.azure.com/<org>`), `project`, the work item type at each level of the hierarchy (`epicWorkItemType`, `featureWorkItemType`, `workItemType` for stories, `taskWorkItemType`), `humanWorkItemType`, optional `areaPath` and `iterationPath`, `priorityField`, optional `targetDateField`, `statusMap` and `taskStatusMap`.
- **Hierarchy.** Items follow the process's levels, one at a time: Epic > Feature > User Story > Task. Azure Boards advises linking parents and children only across levels, one deep, and grouping stories under features: under a link within one level (a story under a story), only the leaf shows on boards, and the backlog can't be reordered. The phase's `plan.md` names the root of its tree with one line, chosen by the plan's size, and `board sync` builds the tree under it:

  | Plan line | For | Sync makes |
  | --- | --- | --- |
  | `**Epic:** AB#<n>` | a large plan, several workstreams | one Feature per workstream under the epic, each packet a User Story under its workstream's Feature |
  | `**Feature:** AB#<n>` | a medium plan | each packet a User Story under the feature |
  | `**User Story:** AB#<n>` | a small plan | each packet a Task under the story |

  The root must already exist and be of the type its line names; otherwise sync stops before it writes anything.
  - **Workstreams** come from each packet's `**Workstream:**` field. A packet without one goes under a Feature named after the phase (the plan's heading), which sync tags `phase:<slug>` when it creates it. Sync reuses a Feature under the epic whose title is the workstream's name (an open one first, never a Removed one) and creates the rest, only when an item of the right type goes under it in that run (with or without `-Force`), so phases under one epic share a workstream's Feature. It never deletes a Feature: one whose workstream was renamed stays, empty.
  - **Human tasks** are `humanWorkItemType` (Task), so each sits under a User Story: the packet its `**Parent:**` line names (in any phase), else the first packet that depends on it, else the first packet it depends on. Under a User Story root, they sit beside the packets, and a Parent line gets a note saying it has no effect. A human task with none of these gets a note, and stays where it is.
  - **Moves.** An item has one parent. Sync links an item that has none, and never moves one that has another: someone may have put it there on purpose. It names each such item and its place in the plan's tree instead; `sync -DryRun -Force` lists the moves, and `sync -Force` makes them, as `-Force` makes the packet files win over board edits elsewhere in sync: it also overwrites bodies edited on the board, so move those edits into the packet files first. A board laid out before this tree (every item straight under the epic) needs that once, after the upgrade. The dispatcher's own sync (after an amendment merges) never passes `-Force`, so no agent moves an item.
  - **Type changes.** Sync never changes a work item's type. When the root's level changes after items exist (a Feature root becomes a User Story root, say), it names each item whose type no longer fits, and leaves it where it is; change the type on the board, then sync again.
  - **Packets as tasks.** A config from before this tree that made packets Tasks (`workItemType` the task type) still syncs without a root line; with one, sync stops before writing, because the tree needs a different type at each level. To give such a plan a root, set `workItemType` back to the story type and name a User Story as the root: its packets are then Tasks under it.
  - **Basic process** (Epic > Issue > Task): set `featureWorkItemType` to `""` and `workItemType` to `Issue`. Packets then sit straight under an epic; a `**Feature:**` line is refused. A config from before the hierarchy has no `featureWorkItemType`, so it gets `Feature`: under an epic, sync then stops before writing and says to set it.
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
- **taskStatusMap** is the same map for the task type: for packets under a User Story root, and for human tasks while `humanWorkItemType` is the task type (as by default). Tasks have fewer states than stories in every stock process, so it needs its own. Without it, tasks use `statusMap`, and sync refuses a User Story root whose task type lacks one of its states. Starting points:

  | Status | Agile (Task) | Scrum (Task) | Basic (Task) |
  | --- | --- | --- | --- |
  | Backlog | New | To Do | To Do |
  | Ready | New + `status:ready` | To Do + `status:ready` | To Do + `status:ready` |
  | In progress | Active | In Progress | Doing |
  | In review | Active + `status:in-review` | In Progress + `status:in-review` | Doing + `status:in-review` |
  | Ready to merge | Active + `status:ready-to-merge` | In Progress + `status:ready-to-merge` | Doing + `status:ready-to-merge` |
  | Needs human | Active + `status:needs-human` | In Progress + `status:needs-human` | Doing + `status:needs-human` |
  | Done | Closed | Done | Done |
- **Tags:** `packet`, `human-task`, `size:<S|M|L>`, `wave:<value>`, `phase:<slug>` and the status tags. Priority uses the Priority field (P0 = 1 … P3 = 4).
- **Descriptions** are written as Markdown (`markdown: true`, needs an organization with Markdown support for work item fields). With `markdown: false` the packet text goes in as preformatted HTML, and sync can no longer tell a board-side edit from its own, so it always rewrites.
- **Dependencies** become Predecessor links. They don't move items in the tree.
- **Comments** (claims, briefs) are posted as Markdown comments and deleted through the comments API.
- **Untested against a live organization** in the kit's own tests; run `board setup` and a `sync -DryRun` first.

## local

A JSON board in `<git common dir>/packet-board.json`: every worktree of the clone shares it, nothing is committed, nobody else sees it. For trying the workflow end to end on one machine and for `tests/run-tests.ps1`. Pull requests still go to GitHub.
