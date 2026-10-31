# PKT-2 · Install only the plan, board and progress skills

- **Packet:** PKT-2 · **Priority:** P0 · **Size:** M · **Wave:** W1 · **Workstream:** 1 Plan and board · **Target:** 2026-11-09
- **Depends on:** PKT-1
- **Review lenses:** ops, correctness, tests
- **Locks:** none
- **Initial status:** Ready

## Goal

An engineer whose seat can't pay for a dispatch still gets planning and the board. Planning and the board cost under 1,000 credits a phase. `install.ps1 -PlanOnly` installs packet-plan, packet-board and packet-progress, with no agents and no hook. The README then says how to hand a synced packet to a person, or to the Copilot coding agent on GitHub Issues or Azure Boards.

## Spec

- Workstream 1 of the source request.
- `install.ps1` (the plan list, the manifest and its removal loop, `-WithInstructions`).
- `skills/packet-plan/scripts/validate-packets.ps1`, the known-lens check, which reads `../../packet-review/lenses`.
- Microsoft Learn, "Use GitHub Copilot with Azure Boards": "Create a pull request with GitHub Copilot" on a work item. It needs the GitHub App connection, not a PAT, and work item types in the Requirements or Task category.

## In scope

- `install.ps1 -PlanOnly`:
  - copies only `skills/packet-plan/**`, `skills/packet-board/**` and `skills/packet-progress/**`, plus `skills/packet-dispatch/scripts/check-scope.ps1` on its own: no `.github/agents`, no `.github/hooks`, no packet-review skill, and no other packet-dispatch file. Without `SKILL.md`, the dispatch folder is not a skill, so no `/packet-dispatch` appears;
  - never reads `models`, so an empty or missing models map can't stop it;
  - writes a new config from the full template, so a later full install has the review settings it needs;
  - prints next steps for this mode.
- **The mode in the manifest.** `.github/packet-workflow.kit.json` records `"mode": "plan-only"` or `"mode": "full"`. A manifest without `mode` reads as full.
- **Changing mode.** The flag decides each run; the mode isn't sticky (owner's decision, question 6):
  - A run without `-PlanOnly` on a plan-only install upgrades it to full, and its first line says what it adds.
  - `-PlanOnly` on a full install is refused before anything is written: exit 1, and a list of the files a downgrade would remove.
  - The removal loop only ever removes kit files of the mode being installed.
- `-PlanOnly -WithInstructions` writes `templates/copilot-instructions.plan-only.md` between the same markers. It names only the three skills, and says agents never merge. A later full run with `-WithInstructions` replaces it with the full block.
- `validate-packets.ps1`: when the kit's lens folder isn't next to it, it takes the kit's lens names from `$script:KitLenses`.
- `skills/packet-progress/SKILL.md`: in a repository without `.github/skills/packet-dispatch/SKILL.md` (a plan-only install, whose `packet-dispatch` folder holds only `check-scope.ps1`), the next moves for startable and stale packets are hand-offs, never `/packet-dispatch`. A stale In progress item there means asking the owner.
- `skills/packet-board/SKILL.md`, a short "Without a dispatcher" section:
  - `board set <ID> "Status=In progress"` before a hand-off, and `board assign <ID>` when a person takes it;
  - the PR body's closing line is what `board ref <ID>` prints;
  - before review, the scope check, run from a kit pinned from origin's default branch as packet-dispatch's Preflight step 1 makes it, never from the PR branch's copy (the PR could change the script): `pwsh -File <kit>/.github/skills/packet-dispatch/scripts/check-scope.ps1 -Packet <ID> -Base origin/<default branch> -Head <PR branch>` (it compares from the merge base);
  - after a merge, `board reconcile`.
- `README.md`:
  - The Install section mentions `-PlanOnly`.
  - A new "Plan and board only" quick-start, at most 30 lines: install, configure `repo` and the board, `/packet-plan`, review the plan PR, `/packet-board setup` and `sync`. It ends with three hand-offs:
    1. **By hand:** a person builds it, using the commands above, scope check included.
    2. **GitHub Issues or a GitHub Project:** assign the issue to Copilot; the coding agent works from the issue body, which is the packet file.
    3. **Azure Boards:** on the work item, "Create a pull request with GitHub Copilot".
  - It says what a hand-off doesn't do: no brief, no review panel, no claim; the scope check runs only when someone runs it. The owner reviews the PR, and branch protection is the merge gate. It also says the coding agent's runs draw on the same AI credits and the kit doesn't estimate them.

## Out of scope

- A CI job that runs the scope check on every PR: it needs a rule for finding a PR's packet (a coding agent's PR title is free text), and it is the owner's machinery. A follow-up.
- The Configure table rows and the safety table (PKT-8).
- `-Profile` (PKT-4).

## Owns

- `install.ps1`
- `templates/copilot-instructions.plan-only.md`
- `skills/packet-plan/scripts/validate-packets.ps1`
- `skills/packet-progress/SKILL.md`
- `skills/packet-board/SKILL.md`
- `README.md`
- `tests/cases/plan-only.tests.ps1`
- `docs/decisions/solo-budget/PKT-2.md`

## Shared touchpoints

- none

## Consumes

- `$script:KitLenses`, `New-CaseRepo` and `Remove-CaseRepo` from PKT-1.

## Provides

- `install.ps1 -PlanOnly`, and `mode` in `.github/packet-workflow.kit.json` (`plan-only` or `full`).
- `templates/copilot-instructions.plan-only.md`.

## Acceptance criteria

- [ ] `-PlanOnly` into a fresh repository writes exactly the files under `.github/skills/packet-plan`, `packet-board` and `packet-progress`, `.github/skills/packet-dispatch/scripts/check-scope.ps1` and no other packet-dispatch file, plus the config (the template with `repo` and the default branch filled in) and the manifest (mode plan-only, listing only those files). `-DryRun` writes nothing.
- [ ] `-PlanOnly` succeeds on an existing config with `"models": { "strong": [] }`; the same config without `-PlanOnly` still fails as it does today.
- [ ] From the plan-only install, with a config holding only `repo` and `board.provider` `local` (no `commands`, `models`, `guardrails`, `claims` or `review` keys), these all exit 0 on the sample phase: `validate-packets.ps1`; `board setup`, `sync`, `show`, `next` and `reconcile`; and `progress.ps1 -Json`. The validator warns on a lens `perfromance` and not on `performance`. From the same install, `check-scope.ps1` exits 0 on a branch inside its packet's Owns and 1 on one that edits another packet's path. Run from a pinned kit with `-Head`, it still exits 1 when the branch also edits its own `check-scope.ps1` to print OK.
- [ ] A full run on a plan-only install adds the agents, the dispatch and review skills and the hook, records mode full and says so. A `-PlanOnly` run on a full install exits 1, lists what it would remove, and leaves every file under `.github` and the manifest byte-identical.
- [ ] After any sequence of `-WithInstructions` runs, in either mode, `.github/copilot-instructions.md` holds one marked block: the current mode's.
- [ ] Every existing installer test passes unchanged, so a default install is the same as at the base.
- [ ] The README quick-start gives the three hand-offs, the board commands from the new section, and what a hand-off doesn't do.

## Tests to run

- `pwsh -NoProfile -File tests/run-tests.ps1`

## Decision record

`docs/decisions/solo-budget/PKT-2.md`

## Dispatcher notes

`install.ps1`'s removal loop deletes every manifest file that is no longer in the kit and unchanged since it was installed. A plan-only run on a full install would delete the agents, the dispatch and review skills and the hook, so the refusal must come before that loop, and a test must show nothing is removed. A plan-only install writes the full template on purpose. A trimmed config would leave `review.lensPaths` empty after a later full install, and the panel would then choose fewer lenses by path.
