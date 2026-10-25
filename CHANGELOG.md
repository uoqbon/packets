# Changelog

What each release of the kit changes, newest first. `VERSION` holds the release's version, and the installer records it in `.github/packet-workflow.kit.json`. The [README](README.md#install) shows how to install a release and upgrade to the next one.

## 0.1.1 (2026-10-25)

A fix to what the board skill tells the owner to do with edits made on the board. What sync does is unchanged.

### If you installed 0.1.0

Fetch the tag and check it out (`git -C packets fetch --tags`, then `git -C packets checkout v0.1.1`), and run the installer again. It replaces the board skill's `SKILL.md`, `providers.md`, `board.ps1`, and `azure-boards.ps1`, `github-common.ps1` and `local.ps1` under `scripts/providers/`, and lists any of them you changed and it kept. Commit what it installs in a pull request. Nothing in `.github/packet-workflow.json` changes.

If you followed 0.1.0's message and ran `board sync -Force` after moving edits made on the board into a packet file you hadn't merged, the board may show the old text again: the dispatcher's sync after an amendment writes it back. Move those edits into the packet file in a pull request, merge it, update the checkout, then run `board sync -DryRun` and `board sync`. Until then, the uncommitted packet file may be the only copy of those edits: don't discard it to get past `/packet-dispatch`'s clean-tree check.

### Fixed

- **Merge board edits before `sync -Force`.** `board sync`'s `skipped` line for a body edited on the board, the note on an item outside its place in the tree, and the board skill's docs said to move edits made on the board into the packet files, then run `sync -Force`. They now say to do it in a pull request, merge it and update the checkout first, and the `skipped` line for an item sync didn't create says the same. Sync reads the packet files from the working tree, but the dispatcher's sync after an amendment reads them from the default branch, so an edit left in the checkout reached the board and was then written back. The uncommitted file also stopped a dispatch or a resume at its clean-tree check ([#26]).

### Tests

- The offline tests pin the new note on every board, and both `skipped` lines. On the local board they show that the dispatcher's sync writes back an edit that isn't merged and keeps one that is ([#26]).

## 0.1.0 (2026-10-25)

The first release: the dispatcher, the implementer and three reviewer agents; the plan, board, dispatch, review and progress skills; the hook that refuses to start the dispatcher as a subagent; the installer; and the offline tests, which CI runs on Linux, macOS and Windows. The [README](README.md) explains how it works, and its [known limitations](README.md#known-limitations) say what has run end to end and what hasn't.

### If you installed the kit before this release

`VERSION` has read 0.1.0 since the kit moved to this repository ([#1]), so an install made from `main` before this release records 0.1.0 too, with older files. To upgrade, fetch the tag and check it out (`git -C packets fetch --tags`, then `git -C packets checkout v0.1.0`), and run the installer again. What changes for you:

- **Start and resume a dispatch with `/packet-dispatch`.** The dispatch skill stops when no person started it, and it has refused a person's plain `dispatch` ([#16], [#23]).
- **The installer adds a hook:** `.github/hooks/packet-workflow.json` and `packet-dispatcher-guard.ps1`. Commit them with the rest of the kit ([#23]).
- **Three review tiers instead of four.** The installer removes `packet-reviewer-max` unless you changed it. A packet or a previous round at tier 4 reads as tier 3; move a `review.agents."4"` of your own to `"3"` ([#3]).
- **Agent models still come from your `models` map.** The installer never rewrites an existing `.github/packet-workflow.json`. The template now lists GPT-6.1 Sol first in every class, and a class your `models` map leaves out gets the template's new list ([#2]).
- **Azure Boards: the plan's root line now builds a tree** that follows the process's levels ([#5]). Some older setups now stop sync before it writes, the dispatcher's sync after an amendment included. Fix them in the pull request that upgrades the kit: the scripts read the config from the default branch, and the dispatcher's sync reads the plan files there too.
  - The Basic process, with an `**Epic:**` line naming an Epic: set `board.azureBoards.featureWorkItemType` to `""`.
  - A plan whose `**Epic:**` line names a Feature: change the line to `**Feature:**`.
  - A plan whose `**Epic:**` line names a story-level item (a User Story; a Product Backlog Item on Scrum, a Requirement on CMMI, an Issue on Basic): change the line to `**User Story:**`. Its packets then become Tasks (step 1 below).
  - A config that made packets Tasks (`workItemType` the task type), with a plan that names a root: set `workItemType` back to the story type, and name a User Story as the root.
  - A custom process whose types aren't named Epic, Feature and Task: set `epicWorkItemType`, `featureWorkItemType` and `taskWorkItemType` to its names.
  - Wherever packets are Tasks under a story and the task type lacks a state that `statusMap` uses (on Agile, `Resolved`): add `board.azureBoards.taskStatusMap`. [providers.md](skills/packet-board/providers.md) has starting points.

  Until the steps below, sync leaves an item laid out before the tree where it is and names it. Once the pull request has merged, work from an up-to-date checkout of the default branch, since sync reads the plan files from the working tree:
  1. Where packets became Tasks under a story: sync never changes a work item's type, and changing it on the board resets the item's State. While no packet of the phase has a live claim (`board claims <ID>` prints nothing), note each packet's status (`board show -Phase <phase>`), change each packet item to the task type, and put its status back with `board set <ID> "Status=<status>"`, Done included. A Removed item reads as Done too: set its State back to Removed on the board instead.
  2. Run `board sync -DryRun`: each `skipped` line names a body edited on the board or an item sync didn't create. With `markdown: false` sync can't tell an edit, so compare the descriptions by hand. Then run `board sync -DryRun -Force` to see the moves and updates. Move those edits into the packet files in a pull request, merge it, and update the checkout.
  3. Run the dry run again, then run `board sync -Force` once.

### Added

- **Dependencies on other repositories.** `remotes` maps a packet ID prefix to another GitHub repository, so a packet can depend on a packet there. `validate-packets`, `board next`, `board deps` and `progress` read it ([#4]).
- **The Azure Boards hierarchy.** `board sync` builds the tree from the plan's root, one level at a time: under an Epic, a Feature per workstream with the packets as its User Stories; under a Feature, the packets as User Stories; under a User Story, the packets as Tasks ([#5]).
- **A parent for a human task.** A human task can name the packet it sits under on the board (`- **Parent:** <ID>`) ([#6]).
- **A host hook against subagent starts of the dispatcher.** Where the Copilot runtime runs repository hooks, it refuses a `task` call that names `packet-dispatcher` ([#23]). The dispatcher and the dispatch skill also check who started them, and the dispatcher names every subagent it starts ([#14], [#16]).

### Changed

- **Three review tiers,** light, standard and deep, none above high reasoning effort. The deep reviewer takes over `packet-reviewer-max`'s adversarial checks ([#3]).
- **Default models:** GPT-6.1 Sol first in every class, Claude Sonnet 5.5 second ([#2]).
- **Sync never moves an item that has another parent,** on any board. It names the item and leaves it there; `sync -DryRun -Force` lists the moves and `sync -Force` makes them. `-Force` also overwrites bodies edited on the board, so merge those edits into the packet files first. On GitHub, sync used to add a second parent, which GitHub refused, and stop. A GitHub or local dry run now reads the board and prints what it would link and move ([#5], [#6]).
- **Claims renew only when due,** by the board's clock: `board claim` posts a renewal once a third of the lease has passed, not at every milestone ([#12]).
- **`/packet-dispatch status` runs on a checkout that isn't clean.** A dispatch or a resume still stops on one ([#20]).

### Fixed

- **Azure Boards tags** are replaced rather than added to, so an item no longer keeps its old status, size, wave and phase tags ([#10]).
- **Azure Boards Markdown** descriptions and comments are decoded on read. `board sync` no longer skips a packet with `"` or `>` in it as edited on the board, and a brief re-read from its marker comment reads as written ([#17], [#18]).
- **Dates in other cultures.** Every date the kit formats or parses uses the invariant culture. Under th-TH or fi-FI, claim times, claim ids, progress dates and the Azure Target date came out wrong ([#22]).

### Tests and docs

- CI runs the offline tests on Linux, macOS and Windows for every pull request and every push to `main` ([#7]). They also check the kit's files for trailing whitespace ([#13]).
- [tests/copilot-e2e-azure-story.prompt.md](tests/copilot-e2e-azure-story.prompt.md) runs the e2e stages on Azure Boards, with packets as Tasks under an existing User Story ([#8]). What its first run found closed gaps in both e2e prompts ([#11], [#19], [#21]).
- `.claude/cloud-setup.sh` installs PowerShell for Claude Code cloud sessions ([#9]).
- The README records what has run live since the kit moved here: the Azure story run, and the S8.7 run in which the hook refused a dispatcher start ([#22], [#24]).

[#1]: https://github.com/uoqbon/packets/pull/1
[#2]: https://github.com/uoqbon/packets/pull/2
[#3]: https://github.com/uoqbon/packets/pull/3
[#4]: https://github.com/uoqbon/packets/pull/4
[#5]: https://github.com/uoqbon/packets/pull/5
[#6]: https://github.com/uoqbon/packets/pull/6
[#7]: https://github.com/uoqbon/packets/pull/7
[#8]: https://github.com/uoqbon/packets/pull/8
[#9]: https://github.com/uoqbon/packets/pull/9
[#10]: https://github.com/uoqbon/packets/pull/10
[#11]: https://github.com/uoqbon/packets/pull/11
[#12]: https://github.com/uoqbon/packets/pull/12
[#13]: https://github.com/uoqbon/packets/pull/13
[#14]: https://github.com/uoqbon/packets/pull/14
[#16]: https://github.com/uoqbon/packets/pull/16
[#17]: https://github.com/uoqbon/packets/pull/17
[#18]: https://github.com/uoqbon/packets/pull/18
[#19]: https://github.com/uoqbon/packets/pull/19
[#20]: https://github.com/uoqbon/packets/pull/20
[#21]: https://github.com/uoqbon/packets/pull/21
[#22]: https://github.com/uoqbon/packets/pull/22
[#23]: https://github.com/uoqbon/packets/pull/23
[#24]: https://github.com/uoqbon/packets/pull/24
[#26]: https://github.com/uoqbon/packets/pull/26
