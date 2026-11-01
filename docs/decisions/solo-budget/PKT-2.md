# PKT-2 · Decision record

Choices [PKT-2](../../plan/solo-budget/packets/PKT-2.md) left open, and why each went the way it did.

## The plan-only install

1. **The plan-only set is a path rule, `Test-PlanOnlyFile`.** A file is in it if its installed path is under `.github/skills/packet-plan/`, `packet-board/` or `packet-progress/`, or is exactly `.github/skills/packet-dispatch/scripts/check-scope.ps1`. The installer builds the full list as before, then keeps only those files. The same rule decides the refusal and the removal loop, so the three can't disagree. A new file in one of the three skills is picked up without a change here.
2. **`models` isn't read at all in plan-only mode.** The loop over `strong`, `standard` and `light` runs over nothing, so an empty, broken or missing map can't stop it, and the "Agent models" line isn't printed. The config is still parsed when it exists (a file that isn't JSON still stops the run), because the board and progress would fail on it next anyway.
3. **A new config is the full template**, with `repo`, `defaultBranch` and `guardrails.protectedBranches` filled in by the same code as a full install. That's what the Dispatcher notes ask for: a trimmed config would leave `review.lensPaths` empty after a later full install. An existing config is never rewritten, in either mode.
4. **The next steps say what plan-only needs from the config** (`repo` and the board) and point to the README's "Plan and board only" section for the hand-offs. They end with how to add the rest: run the installer without `-PlanOnly`.

## The mode and changing it

5. **The manifest's `mode` is `"plan-only"` or `"full"`**, written between `version` and `installedAt`. Only the exact string `plan-only` reads as plan-only. A manifest without `mode` (0.1.x), or with anything else in it, reads as full. That is the safe reading: a mode the installer doesn't know can only make `-PlanOnly` refuse, never let it remove files.
6. **What counts as "a full install" for the refusal** is a file, not the recorded mode: any manifest file outside the plan-only set that is still on disk. That is exactly what the removal loop could touch, so it is the list the refusal prints. A file changed locally is listed too: the loop would keep it, but it would be left behind in a repository the manifest calls plan-only. Two things follow:
   - A manifest from before modes, or one that says `full`, is refused while its agents and hook are there.
   - Once someone deletes the listed files (in a pull request, as the review notes and the README suggest), `-PlanOnly` goes ahead and records plan-only. That is the downgrade path; there is no `-Downgrade` flag.
7. **The refusal runs right after the manifest is read**, before the config is read or created, before the plan is built and before the removal loop. It writes to stderr, says nothing was written and how to keep the full install or downgrade, and exits 1 (the packet's code; the installer's other errors also exit 1 through `throw`). `-DryRun` is refused the same way. A test snapshots every file under `.github`, the manifest included, and checks it byte for byte after the refused run.
8. **The removal loop, in plan-only mode, skips every file outside the plan-only set.** After the refusal none of them is on disk, so they just drop out of the manifest. If one somehow were there, it is kept in the manifest rather than removed. A full run removes as it did before.
9. **A full run on a plan-only install prints one line before anything else:** `This run makes the plan-only install full: it adds the agents (.github/agents), the packet-dispatch and packet-review skills and the hook (.github/hooks).`, with a dry-run note under `-DryRun`. It is the first line of output. The self-install warning, when there is one, goes to the warning stream before it. A full run on a full or 0.1.x install prints nothing new, so a default install's output is the same as at the base.

## The instructions block

10. **`-PlanOnly -WithInstructions` uses `templates/copilot-instructions.plan-only.md`**, between the same markers, so either mode's run replaces the other's block. The plan-only block has the full block's rules that still apply (the files, the config, agents never merge, owned paths, decision records). It drops the dispatcher, worktree and agent lines.
11. **One block, whatever the file held.** The first marked block becomes this mode's, and any further one is removed. Before, every block was replaced, so a file with two kept two. A default install with one block is unchanged.
12. **Without `-WithInstructions`, a mode change says the block is stale.** When the mode changes and the file still has a marked block, the summary says `copilot-instructions.md still holds the <mode> install's workflow rules: rerun with -WithInstructions to replace them.` The file isn't touched, since a run without the flag never wrote it before either.

## The validator

13. **The kit's lens names come from `$script:KitLenses` only when `../../packet-review/lenses` isn't a folder.** When the folder is there (a full install, or the kit's source), the validator reads it as before. The project's lens folder and `review.lensPaths` add to either. With a config holding only `repo` and the board, `review.lensPaths` is empty, so without the fallback the known set would be empty and no lens would warn. The test shows that: with the fallback line removed, its `perfromance` case fails.

## The skills and the README

14. **The progress skill checks for `.github/skills/packet-dispatch/SKILL.md` first**, in Judge, and the bullets that suggest `/packet-dispatch` (merges, capacity, stale work) each say what to do without it. Stale work there means asking the owner, since a hand-off leaves no claim to read.
15. **The board skill's "Without a dispatcher" section spells out the pin**, using the same `git archive` and `Expand-Archive` commands as packet-dispatch's Preflight step 1, then the scope check with `-Head`. It says what `<PR branch>` is (`origin/<branch>`, or a `pull/<n>/head` fetch for a fork) and what exits 0, 1 and 2 mean.
16. **The README's quick-start is a section of its own, "Plan and board only"**, after Use: 14 lines with the blank ones. It links to the board skill's section for the commands rather than repeating the pin. It ends with what a hand-off doesn't do, the credits note, and the downgrade path. The Configure table and the safety table are PKT-8's.

## Tests

17. **The tests are in `tests/cases/plan-only.tests.ps1`** (35 assertions). They follow PKT-1's case-file rules: plain variables, kit code only through `Invoke-Kit` and `New-CaseRepo`, nothing dot-sourced. The fresh-repository install uses a bare `git init` with a GitHub origin URL and `origin/HEAD` at `trunk`, so the test also shows the default branch is filled in.
18. **The plan, board and progress run edits the sample phase first.** `New-CaseRepo`'s phase fails `validate-packets.ps1` with any config, on purpose: PKT-05 is the suite's overlap and lock case. PKT-02's `Locks: migrations` also needs a `locks` key, which a config of only `repo` and the board doesn't have. So the test deletes PKT-05 and sets PKT-02's Locks to none, and gives PKT-04 the lenses `ux, performance, perfromance`. `tests/run-tests.ps1` isn't in Owns, so `Write-SamplePhase` is unchanged.
19. **The forged scope check is shown both ways.** On a branch that rewrites its own `check-scope.ps1` to print OK, that copy exits 0. The copy pinned from `origin/main` and run with `-Head` exits 1 and names the script as MACHINERY.

## Names that differ from the packet

- None. The packet's `$script:KitLenses`, `New-CaseRepo` and `Remove-CaseRepo` are what PKT-1 merged. `Invoke-Kit`, also from the runner, runs the installed scripts.
