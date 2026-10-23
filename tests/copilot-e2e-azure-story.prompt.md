---
name: packet-kit-e2e-azure-story
description: "End-to-end verification of the packet workflow kit on Azure Boards, where the phase's packets become Tasks under a User Story that already exists. Run stage by stage on a sandbox repository."
argument-hint: "[stage 1-9 | status] (default: the next unfinished stage)"
agent: agent
---

# Packet kit end-to-end verification: Azure Boards, existing User Story

You are the **verifier** for the packet workflow kit, in one scenario: the team tracks work in **Azure Boards**, a product owner has already written a **User Story** there, and the packet workflow plans the code for it and adds its packets as **Tasks under that story** (the plan's `**User Story:** AB#<n>` root line). Code and pull requests stay on GitHub. You run this test plan one stage at a time on a **sandbox** repository, collect evidence for every check, and write a report. Between some stages the owner (me) runs real dispatcher sessions; you then check what they left on the board and on GitHub. You are an observer: you never stand in for the dispatcher, the implementer or the review panel, and you never fix the kit yourself.

This prompt is a companion to [copilot-e2e.prompt.md](./copilot-e2e.prompt.md) (the **base prompt**: GitHub issues, the TextKit phase). Where a step below says "as in base S5.3", read that check in `<kitSource>/tests/copilot-e2e.prompt.md` and run it here, with this scenario's phase, packets and board. Everything Azure-specific is written out here.

Inputs (if one is still a literal `${input:…}` placeholder, ask me for it before anything else):

- Kit source folder (holds `install.ps1`, `skills/`, `agents/`, `tests/`): `${input:kitSource:path to the kit source folder, e.g. ../packets}`
- Sandbox repository on GitHub (owner/name): `${input:sandboxRepo:owner/name of a throwaway repository}`
- Azure DevOps organization URL: `${input:abOrg:e.g. https://dev.azure.com/my-org}`
- Azure DevOps project: `${input:abProject:project name}`
- The existing User Story's work item ID: `${input:story:the number in AB#<n>}`
- Stage to run: the argument after the command, or `${input:stage:stage number, status, or empty for the next one}`

## Ground rules

The base prompt's ground rules 1 to 7 apply (sandbox only, never merge, pinned kit, evidence, state outside git, stop at ⏸, note values in `state.md`). On top of them:

1. **The story is the owner's.** The kit may add child links to it, and nothing else: never change its title, description, acceptance criteria, state, tags, assignee, area or iteration, and never move or delete the items that were under it before the run. The checks below prove the kit didn't either.
2. **Azure DevOps through the REST API with the PAT, never `az`.** `AZURE_DEVOPS_EXT_PAT` must be set in the terminal VS Code runs (a PAT with Work Items Read & write); the kit reads it, and so do you. Never print it, never write it to a file, never put it in a URL. In stage 1, write `.packet-e2e/ab.ps1`, a helper that every Azure check below goes through:

   ```powershell
   # ab.ps1 <path relative to the project, or /org/<path>> [-Method GET] [-Body <json string>] [-ContentType application/json]
   param([Parameter(Mandatory)][string]$Path, [string]$Method = 'GET', [string]$Body, [string]$ContentType = 'application/json')
   $org = '<abOrg>'; $project = '<abProject>'
   if (-not $env:AZURE_DEVOPS_EXT_PAT) { [Console]::Error.WriteLine('AZURE_DEVOPS_EXT_PAT is not set'); exit 2 }
   $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$env:AZURE_DEVOPS_EXT_PAT"))
   $base = if ($Path.StartsWith('/org/')) { "$org/$($Path.Substring(5))" } else { "$org/$([uri]::EscapeDataString($project))/$Path" }
   $sep = if ($base.Contains('?')) { '&' } else { '?' }
   $uri = if ($base -match 'api-version=') { $base } else { "$base${sep}api-version=7.1" }
   $req = @{ Uri = $uri; Method = $Method; Headers = @{ Authorization = $auth }; ContentType = $ContentType }
   if ($Body) { $req.Body = $Body }
   try { Invoke-RestMethod @req | ConvertTo-Json -Depth 20 } catch { [Console]::Error.WriteLine($(if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message })); exit 2 }
   ```

   Fill in the organization and project. Below, `ab <path>` means `pwsh -File .packet-e2e/ab.ps1 <path>`. Single-quote every path that holds a `?` or a `$` (zsh treats `?` as a glob, and both shells expand `$expand`). Useful paths: `'_apis/wit/workitems/<id>?$expand=all'` (fields, relations and `multilineFieldsFormat`), `_apis/wit/workItems/<id>/updates`, `_apis/wit/workItems/<id>/comments?api-version=7.1-preview.4`, and `_apis/wit/wiql` (POST, body `{"query":"…"}`).
3. **Scratch items are yours to remove.** A probe that creates a work item sets it to `Removed` when it's done, or, where its type has no Removed state (Basic), to the type's done state with the tag `e2e-scratch` (a state change, which the owner can undo), and lists it in the report. Never delete a work item, and never touch one you didn't create, apart from the edits a probe makes and reverts on a packet's own Task.

## Stage 1 · Environment, discovery and the story

1. Run base stage 1, items 1 to 7, as written, with IDs `Base S1.<n>` so they don't clash with this stage's. Base S1.4 can end `HOST`: the host lists the dispatcher although the kit's file opts out. Record the fields that check names, not a plain FAIL.
2. **PAT.** `pwsh -NoProfile -Command '[bool]$env:AZURE_DEVOPS_EXT_PAT'` prints `True`. Write `.packet-e2e/ab.ps1` (ground rule 2), then `ab '/org/_apis/connectionData?api-version=7.1-preview'` names the authenticated user: record its `authenticatedUser.properties.Account.$value` (the unique name the kit trusts as the signed-in user).
3. **Process.** `ab '/org/_apis/projects/<abProject>?includeCapabilities=true'` gives the process template (`capabilities.processTemplate.templateName`). Record it: Agile, Scrum, Basic or CMMI. It decides the work item types and the two status maps in stage 2 (`<kitSource>/skills/packet-board/providers.md`, section azure-boards, has a starting point for each).
4. **The story.** `ab '_apis/wit/workitems/<story>?$expand=all'`:
   - its `System.WorkItemType` is the process's story type (User Story in Agile, Product Backlog Item in Scrum, Issue in Basic, Requirement in CMMI), and it has no `packet` tag;
   - record its `rev`, `System.State`, `System.Title`, `System.Tags`, `System.AreaPath`, `System.IterationPath`, `System.AssignedTo`, and a SHA-256 of `System.Description` and of the acceptance-criteria field (`Microsoft.VSTS.Common.AcceptanceCriteria`, where the type has it), in `state.md` and in `.packet-e2e/story-before.json`;
   - record its children (relations with `rel` = `System.LinkTypes.Hierarchy-Forward`): their IDs, types, titles and `rev`. These are the **pre-existing children**; the run must leave every one of them as it is.
5. **Azure Boards app.** Ask me whether the Azure Boards app for GitHub is installed on the sandbox and connected to this project (Project settings > GitHub connections). With it, `Fixes AB#<task>` in a PR body links the PR to the Task and closes the Task when the PR merges. Without it, I close each Task by hand after its merge: record that, and in stage 5 the merge-close check becomes MANUAL.

## Stage 2 · Offline suite, installer and Azure config

1. Run base stage 2, items 1 to 3 (offline suite, install, second install).
2. Check and set `.github/packet-workflow.json`:
   - `repo` is the sandbox; `commands.ci` is `pwsh -File tests/run-all.ps1`; `trustedAuthors` is empty unless I name a second account;
   - `review.deepPaths` is the regex `^src/draftmeta/Core\.ps1$` (in the JSON: `"^src/draftmeta/Core\\.ps1$"`), so stage 8 has a project raise to try to remove;
   - `board.provider` is `azure-boards`, and under `board.azureBoards`: `organization` and `project` from the inputs; `epicWorkItemType`, `featureWorkItemType`, `workItemType`, `taskWorkItemType` and `humanWorkItemType` for the process from stage 1 (Agile: Epic, Feature, User Story, Task, Task; Basic: Epic, `""`, Issue, Task, Task); `statusMap` and `taskStatusMap` from providers.md's tables for that process; `doneStates` holding the process's done states (Agile: `Closed`, `Removed`; Basic: `Done`); `areaPath` and `iterationPath` empty; `markdown` true;
   - `models`, as in base S2.4.
3. Commit nothing yet; stage 3 commits everything together.

## Stage 3 · Plan to packets under the story

1. Write the mini plan below to `docs/specs/draftmeta.md`, with the story's real ID in place of `<story>`. It's the input for `/packet-plan`. Don't write the packets yourself.
2. Add the scaffold the spec says already exists, so the planner sees it and the packets don't own it:
   - `tests/run-all.ps1` runs every `tests/*.tests.ps1` with `pwsh -File` and exits 1 if any of them fails (and 0 when there are none yet);
   - `.github/workflows/ci.yml` runs on `pull_request` against the default branch, on `ubuntu-latest`, with the step `pwsh -File tests/run-all.ps1`;
   - `src/draftmeta/DraftMeta.ps1`, the entry point that dot-sources the modules, starts empty apart from a comment.
3. ⏸ Ask me to run, in a **new** chat session (Agent, default agent), `/packet-plan docs/specs/draftmeta.md e2e-draftmeta`, adding on a new line of the same message `The phase belongs to the existing User Story AB#<story>.`, and to come back when it says it's done. Tell me before I go: if the planner asks about item 4's time budget, answer "keep it exactly as written; it's behind the cut line" (stage 7 needs it); if it asks whether item 5 belongs to item 2, say yes.
4. When I'm back, check what it produced:
   - `docs/plan/e2e-draftmeta/plan.md` has exactly one root line, `**User Story:** AB#<story>`, and no `**Epic:**` or `**Feature:**` line (the planner chose the root by the plan's size, small, from the item I named); its heading is the phase's name with no placeholder text; it has a packet index, a Mermaid graph, a critical path, and a `## Shared touchpoints` table listing `src/draftmeta/DraftMeta.ps1`;
   - one packet file per spec item 1 to 4, plus a human task for item 5; the human task's `**Parent:**` line names the reading-time packet (record what it says if not: S4.3 then has nothing to note);
   - each packet has `Owns`, `Acceptance criteria` as `- [ ]`, backticked `Tests to run`, and `Review lenses`; no packet owns the scaffold (`tests/run-all.ps1`, `.github/workflows/ci.yml`, `src/draftmeta/DraftMeta.ps1`), and the feature packets list `DraftMeta.ps1` as a shared touchpoint;
   - the reading-time and slug packets depend only on the foundation and own disjoint paths;
   - the excerpt packet has `**Initial status:** Backlog` and still has the "under 0 milliseconds" criterion (otherwise FAIL, restore it in the packet and the plan, and rerun the validator).
5. `pwsh -File .github/skills/packet-plan/scripts/validate-packets.ps1 -Phase e2e-draftmeta` reports 0 errors.
6. **Negative probe: two roots.** Temporarily add a second root line, `- **Epic:** AB#<story>`, to `plan.md` and run the validator: expect an `ERROR` that the plan `names more than one root item`. Restore the file and confirm 0 errors again.
7. ⏸ Commit all of this (the kit from stage 2, the spec, the scaffold and the plan) on a branch `e2e/setup`, push it, and open a PR. Ask me to merge it, then to come back for stage 4.

### Mini plan (write this to `docs/specs/draftmeta.md`)

```markdown
# DraftMeta: reading time and slug for a draft

Implements the user story AB#<story>, "Show reading time and a URL slug for a draft before publishing".
Every piece of work below is a task under that story.

Goal: a small PowerShell module that gives a blog draft its publishing metadata. Plain PowerShell 7 with no
modules to install. Tests are scripts under tests/ that throw on failure and run with `pwsh -File`.

Already in the repository (not packet work): tests/run-all.ps1 runs every tests/*.tests.ps1, CI
(.github/workflows/ci.yml) runs it on every pull request, and src/draftmeta/DraftMeta.ps1 is the entry point.

Work:
1. Foundation (first, small): src/draftmeta/Core.ps1 with `Split-Words [string]$Text` -> string[]: splits on
   runs of whitespace and punctuation, keeps an apostrophe or hyphen inside a word ("don't", "e-mail"), drops
   empty parts, and returns an empty array for null or empty input. Tests: tests/core.tests.ps1.
2. Reading time (after 1): src/draftmeta/ReadingTime.ps1 with `Get-ReadingTime [string]$Text
   [int]$WordsPerMinute = 200` -> int: the word count from Split-Words divided by WordsPerMinute, rounded up
   (1 for 1 to 200 words, 2 for 201 to 400), 0 for null or empty input; throws when WordsPerMinute is below 1.
   Tests: tests/readingtime.tests.ps1.
3. Slug (after 1, in parallel with 2): src/draftmeta/Slug.ps1 with `ConvertTo-Slug [string]$Text
   [int]$MaxLength = 60` -> string: the words from Split-Words, lower case, accents removed ("Café" -> "cafe"),
   joined by '-', cut at a word boundary to at most MaxLength characters; empty for null or empty input.
   Tests: tests/slug.tests.ps1.
4. Excerpt (optional, behind the cut line): src/draftmeta/Excerpt.ps1 with `Get-Excerpt [string]$Text
   [int]$MaxWords = 30` -> string: the first sentence, cut to MaxWords words with "…" when cut, which must run
   in under 0 milliseconds for any input. Tests: tests/excerpt.tests.ps1.
5. The editor (a person) runs 2 and 3 on three real drafts and says whether the reading times and slugs look
   right. It belongs with item 2 on the board.

Shared file: src/draftmeta/DraftMeta.ps1 dot-sources each module, one line per module; each packet adds its own line.
```

Item 4's criterion can't be met on purpose: stage 7 uses it to check the Needs human path.

## Stage 4 · Board: Tasks under the existing story

Below, `<pkt>` is a packet's Task ID on the board, `<h>` the human task's.

1. **S4.1 Setup.** `board setup -DryRun`, then `board setup`. Expect a `hierarchy:` line with the process's levels (Agile: `Epic > Feature > User Story > Task`; Basic: `Epic > Issue > Task`), a line saying the story type and the task type each have every mapped state, and the GitHub labels for follow-ups. A `MISSING` line is a FAIL of stage 2's config: fix the config, record it, and rerun.
2. **S4.2 Before.** Count the work items tagged `packet` in the project (WIQL `SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.Tags] CONTAINS 'packet'`): expect 0. Record the story's `rev` again; it equals stage 1's.
3. **S4.3 Dry run.** `board sync -Phase e2e-draftmeta -DryRun`:
   - it would create one item per packet and the human task, and would put each of them under `AB#<story>`;
   - it would create no Feature and nothing at any other level;
   - if the human task names a Parent, a note says its Parent line has no effect under `AB#<story>` (a Task can't go under a packet's Task);
   - afterwards the WIQL count is still 0 and the story's `rev` is unchanged: a dry run writes nothing.
4. **S4.4 Sync.** `board sync -Phase e2e-draftmeta`. Record each item's ID in `state.md`. For each, `ab '_apis/wit/workitems/<pkt>?$expand=all'`:
   - `System.WorkItemType` is the task type (Task), for packets and the human task alike: never the story type;
   - exactly one `System.LinkTypes.Hierarchy-Reverse` relation, and its URL ends in `/<story>`;
   - the title is `<ID> · <title>`; the tags hold `packet`, `phase:e2e-draftmeta`, `size:<S|M|L>` and `wave:<Wn>` (packets), `human-task` (the human task), and `status:ready` exactly on the Ready items; State is the task map's state for its status (Agile: `New`; Basic: `To Do`);
   - `Microsoft.VSTS.Common.Priority` is 1 for P0, 2 for P1, 3 for P2;
   - the description is Markdown (`multilineFieldsFormat` says so, or the rendered item in the browser shows headings, not raw `#`) and ends with a `packet:source` marker;
   - each `Depends on` shows as a `System.LinkTypes.Dependency-Reverse` (Predecessor) relation to that dependency's Task; nothing else adds a parent.
5. **S4.5 The story is untouched.** Read the story again and `ab _apis/wit/workItems/<story>/updates`:
   - Title, State, Tags, AreaPath, IterationPath and AssignedTo equal stage 1's; the description's and acceptance criteria's hashes equal stage 1's;
   - its `rev` may not have moved at all: a parent link added from the child's side need not revise the parent (adding the pre-existing child left this project's story at rev 1). Every update after stage 1's `rev`, if any, changes relations only (`relations.added` holding `Hierarchy-Forward` links to the new Tasks) and no `fields` other than the system ones a link bumps (`System.Rev`, `System.ChangedDate`, `System.ChangedBy`, `System.AuthorizedDate`, `System.RevisedDate`, `System.Watermark`); list any other field as a FAIL;
   - its children are now the pre-existing children plus exactly the phase's Tasks.
6. **S4.6 The other children are untouched.** Each pre-existing child still has the story as its parent and the `rev` from stage 1. `board show -Phase e2e-draftmeta` doesn't list them, and `board reconcile -DryRun` doesn't name them (it reads only items tagged `packet`).
7. **S4.7 Idempotent.** A second `board sync -Phase e2e-draftmeta` reports `0 created, 0 updated` and no link or move lines; the story's `rev` doesn't change.
8. **S4.8 Show and next.** `board show -Phase e2e-draftmeta`: the excerpt packet is Backlog and the rest are Ready. `board next -Phase e2e-draftmeta`: only the foundation is `START`; reading time and slug are `BLOCKED` on it.
9. **S4.9 Edit probe.** Change one word in the slug packet's Task description through the REST API (a JSON-patch `replace` on `/fields/System.Description` with `/multilineFieldsFormat/System.Description` = `Markdown`; keep the old text in `.packet-e2e/`), then change one word in that packet's file locally and run `board sync -Phase e2e-draftmeta -WorkingTree`: expect `skipped … edited on the board`. Revert both (the description to its exact old text, the file with `git checkout`), then `board sync -Phase e2e-draftmeta`: unchanged.
10. **S4.10 A Task under another parent.** Create a scratch story, `e2e scratch parent`, of the story type with tag `e2e-scratch`. Move the excerpt packet's Task under it through the REST API (remove its `Hierarchy-Reverse` relation by index, add one to the scratch story). Then:
    - `board sync -Phase e2e-draftmeta` leaves it there and prints a note naming it, the scratch story, and `AB#<story>` as its place, saying `-Force` moves it;
    - `board sync -Phase e2e-draftmeta -DryRun -Force` prints `would move … under AB#<story> (now under AB#<scratch>)` and writes nothing;
    - `board sync -Phase e2e-draftmeta -Force` prints `moved …`, and the Task's only parent is the story again.
    Retire the scratch story as ground rule 3 says and record its ID for the report.
11. **S4.11 A wrong root stops sync before it writes.** In the working tree only, change `plan.md`'s root line to `**Epic:** AB#<story>` and run `board sync -Phase e2e-draftmeta -WorkingTree -DryRun`: expect exit 2 and a message that `AB#<story>` is of the story type and the line should name an Epic or use the line for its type. On a process without features (Basic, `featureWorkItemType` `""`), also try `**Feature:** AB#<story>`: exit 2, saying the process has no features. Then make it `**User Story:** AB#<a pre-existing child Task>` (if the story has none, a phase Task): exit 2 again, naming the Task type. Restore `plan.md` (`git checkout`) and check that no work item changed (`rev`s of the story and of each phase Task as before).

## Stage 5 · Dispatch the foundation packet

1. ⏸ As base stage 5 item 1, with `dispatch <foundation ID>`.
2. When I'm back, run base S5.1 to S5.12 for the foundation, reading `board …` against this board, with these differences:
   - **S5.2 Status** maps to the Task's State and tags through `taskStatusMap` (Agile: In review is `Active` + `status:in-review`, Ready to merge `Active` + `status:ready-to-merge`; Basic: `Doing` + those tags). Exactly one `status:*` tag is on the Task.
   - **S5.4 PR:** the body's first line is the Task's reference, never the story's. The kit writes `board ref <ID>`, which is `Fixes AB#<pkt>` with the **Task's** ID. With the Azure Boards app installed, the app rewrites that mention into a link a few seconds after each body edit; the kit doesn't do that, and it is expected. Accept either form of the first line:
     - **plain:** `board ref <ID>` exactly;
     - **app-linked:** `Fixes [AB#<pkt>](<organization>/<project>/_workitems/edit/<pkt>)`, where `<pkt>` is the Task's ID (the same number in both places, so the story's ID never matches), `<organization>` is the whole configured `organization` value, scheme included (`https://dev.azure.com/<org>`), without a trailing slash, and `<project>` is the configured project's name, URL-encoded (a space is `%20`), or the project's GUID (`ab _apis/projects/<project>` returns it). Match the whole line, case-sensitively, as literal text (escape the dots and any other regex characters in the URL).

     A stacked packet's first line (the PR template) adds ` · Stacked on #<n>; merge that first` after either form; allow that one suffix and no other text. Anything else on the line (another number, another organization or project, other text, `Closes` or `Resolves` in place of `Fixes`) is FAIL.

     When the line is app-linked, also read the body's edit history and show who wrote each version of the line: `gh api graphql -f query='query{repository(owner:"<owner>",name:"<repo>"){pullRequest(number:<n>){author{login} userContentEdits(first:20){nodes{editedAt editor{login} diff}}}}}'`. PASS only if every edit that sets the line to the plain form was made by the PR's author (the dispatcher, whatever login `gh` runs as) and every edit that sets it to the linked form was made by the Azure Boards app (login `azure-boards`, or whatever login the first rewrite records, named in the report). An edit by anyone else that changes the first line (a person, or another bot) is FAIL, even if the result matches the pattern. If the history shows the author never wrote the plain form, or doesn't show the first line's changes at all, record FAIL with the output, not PASS. Record the PR number, the edit times and the logins in the report.

     Grep the whole PR body, case-insensitively: no line has a closing keyword (`close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`, with an optional colon) followed by `AB#<story>` or `[AB#<story>](`, in either form. For example `grep -iE '(clos|fix|resolv)(e|es|ed)?:?[[:space:]]+\[?AB#<story>([^0-9]|$)'` finds nothing (a merge would close the story).
   - **S5.13 Claims and markers as work item comments.** `ab '_apis/wit/workItems/<pkt>/comments?api-version=7.1-preview.4'`: the brief and the hand-off are there as Markdown comments by the user from stage 1 item 2, and no claim comment is left (`board release` deleted it).
   - **S5.14 PR linked.** With the Azure Boards app, the Task has an `ArtifactLink` relation named `GitHub Pull Request`. Without it, N/A.
   - **S5.15 Story still untouched.** As S4.5, against the story's updates since S4.7 (the parent-link removal and re-add for the excerpt packet's Task that S4.10 made, if the story recorded them, are the probe's, not the kit's): the dispatcher changed only its Task, never the story (its State included: record it, and if it moved, say whether a team rule did it, from the update's `revisedBy`).
3. ⏸ If S5.12 found a contract question, handle it as in base stage 5 item 3. Then ask me to merge the PR. Then:
   - **S5.16 Close on merge.** Just before I merge, read the PR body's first line (`gh pr view <n> --json body`) and record which form it has: plain or app-linked (S5.4). With the app, the Task is in a done state within a few minutes of the merge (`ab _apis/wit/workitems/<pkt>`); without it, ask me to close it and record MANUAL. The story is not closed. The report states, for each PR, the form at merge and whether the Task closed, so the run shows whether the app-linked form closes the Task. If it was app-linked and the Task didn't close, that is FAIL, a finding about the app's link, not the dispatcher.
   - `board reconcile` makes the foundation Done, and `board next -Phase e2e-draftmeta` shows reading time and slug `START`.

## Stage 6 · Two dispatchers in parallel, then a conflict

Run base stage 6 as written, for the reading-time and slug packets, with `DraftMeta.ps1` as the one shared file. For S6.2, `board claims <ID>` reads claim comments on the Task: after the probe's `LOST`, the comments API shows no comment from `e2e-probe` left behind. For each packet, also run S5.13 to S5.16.

## Stage 7 · Needs human, answer, resume

Run base stage 7 as written, for the excerpt packet, with these differences:

- The `packet:needs-human` comment is a comment on the excerpt packet's **Task** in Azure Boards (S5.13's API), and the Task carries `status:needs-human` and the task map's State for Needs human.
- ⏸ I answer as a comment on that Task in Azure Boards, not on GitHub. `board comments <ID>` shows the answer under my unique name from stage 1 item 2.
- The answer I post is: "Replace the timing criterion with: the best of 3 runs of `Get-Excerpt` on a 10,000-word input takes under 500 ms." (base stage 7 names TextKit's `Measure-Text`, which this phase doesn't have).
- The amendment PR doesn't say `Fixes AB#` for any item, in either form: its body has no closing keyword (`close`, `fix`, `resolve` and their forms, any case) followed by `AB#<n>` or `[AB#<n>](…)`.

## Stage 8 · Safety probes and the story at the end

1. Run base stage 8, items 1 to 3 and 6, with `src/draftmeta/` in place of `src/textkit/` and `e2e-draftmeta` in place of `e2e-textkit` (the reading-time and slug packets are the two feature packets). Item 4 (a forged round) stays MANUAL without a second account; item 5 (locks) is N/A, since no packet holds one.
2. **Forged board answer (needs a second Azure DevOps user; otherwise MANUAL).** As that user, comment on a packet's Task a line starting with `` `packet:round 9 `` or an answer to a Needs human question. `board comments <ID>` and `board marker <ID> needs-human` don't show it.
3. **S8.7 The story at the end.** As S4.5, against every update since stage 1, exempting S4.10's parent-link removal and re-add for the excerpt packet's Task: over the whole run, the kit changed only the story's child links. Its children are the pre-existing ones (each with its stage 1 `rev`) and the phase's Tasks. Ask me whether to close the story now that its Tasks are done; the kit never does it, and the check is that it didn't.

## Stage 9 · Report

Write `.packet-e2e/report.md` as in base stage 9, and add:

- **Summary:** the Azure DevOps organization, project, process, the story's ID and title, and whether the Azure Boards app was connected.
- **Board tree:** the story with its children after the run, each with type, State, tags and the PR that closed it.
- **Azure notes:** anything Azure Boards did that the kit didn't expect (a rule that moved the story's State, a Markdown field that rendered as raw text, a comment API that rejected a call), with the update or response that shows it.
- **Clean-up list for me:** as in base stage 9, plus every work item the run created (the phase's Tasks and the scratch story from S4.10, already retired) and the story itself. Remove nothing else yourself.

## `status`

With `status` as the argument, read `.packet-e2e/state.md` and print each stage with its checks and results, then name the next stage and what it needs from me first.
