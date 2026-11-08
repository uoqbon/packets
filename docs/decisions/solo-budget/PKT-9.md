# PKT-9 · Decision record

Choices [PKT-9](../../plan/solo-budget/packets/PKT-9.md) left open, and why each went the way it did. The stages are in `tests/copilot-e2e.prompt.md`, after stage 9. H-4 runs them.

## Where the stages go

1. **After stage 9, as stages 10, 11 and 12, under a short preamble.** Stage 9 is the report, so the new stages come after it, but no existing number moves: the README and the tests cite S1.4, S5.11, S8.7 and S8.8. The preamble says what the three stages add to the ground rules. Each new stage ends by adding its own section to `report.md`, laid out the way stage 9 lays out the report. The frontmatter's `argument-hint` now reads `stage 1-12`.
2. **Each stage asks for its sandbox when it starts. There are no new `${input:…}` placeholders.** The prompt asks for every placeholder before anything else. New placeholders would make a run of stages 1 to 9 ask for two sandboxes it never uses. Stage 10 needs a second sandbox, because a plan-only install can't share a repository with a full one: `-PlanOnly` is refused on a full install. Stage 11 needs a fresh one, because `-Profile` only chooses the template for a new config. Stage 12 continues in stage 11's sandbox, which already has the solo config, the plan and the board. Ground rule 1 then applies to whichever sandbox the stage names. H-4 asks for exactly these two sandboxes.
3. **Check IDs follow the existing format** (`S10.1` and so on, numbered by check, not by step). The ⏸ checkpoints tell the owner what to do and what to paste back, as stages 5 to 8 do. Any check that only a second account can run is MANUAL without one, as S8.4 is.

## Credits

4. **Each stage opens with an "Expected credits" line, and closes with a Credits check against the AI usage report.** The figures come from docs/cost.md (`packet-plan` per phase, board sessions, the per-run table, `resume` at 40, the model rates) and from the solo table in the review notes (a solo S packet at 675 typical, 370 for one clean round, 815 when forced to tier 3). The packet says the expected credits come "from the cost page". The cost page has no solo figures until PKT-8, which is being built in parallel, so the review notes' table stands in. H-4 can re-read the figures against PKT-8's page.
5. **A Credits check passes within 0.6× to 1.75× of its figure.** That is the cost page's own range. Outside it, the check fails and names `budget.creditsPerRun` and the cost page, which H-2 calibrates. If the report can't show the stage's window, the check is BLOCKED, never PASS. The verifier's own chat session falls in the same window, so the stage records how much of the total is its own, or that the report can't tell.
6. **A stage that spends credits stops for approval first.** H-4 says paid usage is approved for calibration only (decision 10), so each stage asks the owner to approve its figure before it spends anything.

## Stage 10 · Plan-only

7. **The file list is computed, not listed in the prompt.** The expected set is the plan-only rule in PKT-2's decision 1: every file under the three skills, plus `check-scope.ps1`, plus the config. The verifier builds that list from the kit source. A list typed into the prompt would go stale the first time one of those skills gains a file. On `main` today the set is 17 kit files, and a second run prints `17 file(s) already up to date` (checked offline).
8. **The hand-off follows the board skill's `## Without a dispatcher` section:** In progress before the hand-off, the closing line from `board ref`, the scope check from a pinned kit, and `reconcile` after the merge. The packet asks for the board status at three points (before the hand-off, while the agent works, after the merge) and whether the PR closes the issue. Those are S10.6, S10.7 and S10.9. The scope check (S10.8) isn't in the packet. It is the one guard a hand-off keeps (decision 6 in the review notes), and it costs nothing. An `OUTSIDE` line there is the coding agent's doing, so it is recorded as a note, not a kit failure.
9. **The board provider is the owner's choice, as S2.4 has it.** The stage suggests `github-project`, since its Status field is the one GitHub's own project workflows can move. An Azure Boards hand-off is out of scope (a follow-up), and H-4 keeps it as an item of its own.

## Stage 11 · Solo

10. **The solo sandbox gets its own mini plan, with five S packets.** Stage 3's plan has two feature packets and the slow packet. The slow packet is built to reach Needs human, which would stop stage 12's stops from showing. Stages 11 and 12 need four packets after the foundation: word count for the model-tier stop, two for the ceiling, and a spare in case a round 1 confirms nothing. The plan says each feature item is reviewed with at least correctness and tests. Stage 12 relies on that: with two lenses, round 1 always costs more than `-Next start`'s one-lens round.
11. **The packet's step 7 (the Copilot CLI session limit) runs in step 1's dispatch.** Both need one dispatch end to end, so the limit goes on that dispatch, run from Copilot CLI, and saves a whole dispatch. The limit is 1,500, above the S ceiling plus half, which the review notes suggest for a backstop, so it shouldn't stop the run. Whether it counts the subagents is judged from the ratio of the CLI's spend to the usage report's. The estimator puts a solo S packet's dispatcher at about half its total: 361 of 675 for two rounds, and 193 of 370 for one. So 0.9 or more means the subagents count, 0.7 or less means they don't, and anything in between is BLOCKED with both figures.
12. **`models.strong` is a prioritized list, with the dearer model first and the shipped strong list after it.** One run then answers both of the packet's steps 4 and 6. A refusal is the model-tier stop, and it shows there was no fallback. A round that runs instead shows a fallback, or a host that ignores the tier, and the subagent's header says which. A run on a list with only the dearer model in it could show the stop, but not the fallback. If the host does fall back, the stage says how to get the stop anyway: the dearer model alone, on the reverse packet.
13. **The settle refused after a model-tier stop is checked in stage 11 (S11.10), not stage 12.** The packet lists it under S12, step 4, but the stop exists only between S11.8 and the strong-model resume. Stage 12's answers for H-4 cite S11.10 beside S12.2.

## Stage 12 · The ceiling

14. **The fix window is set with a `packet:budget` raise after a `next=round` stop, not with `budget.maxCreditsPerPacket` itself.** The packet's step 1 says to set the config value between round 1's estimate and that plus the cheapest round after a fix. That window depends on round 1's tier, lenses and runs, which aren't known until review-scope runs on the PR. The dispatcher runs round 1 straight after it opens the PR, so there is no point at which to set it. Two pieces of merged code close the gap:
    - the ceiling is set to `-Next start`'s price. Select then goes through, and round 1's check stops with `next=round`, which the packet's step 4 needs anyway;
    - from that stop, a raise to `so-far + step + implementerFix.S` is exact. Round 1's `outcome=fix` marker books the fix run, so after round 1 the so-far is that sum, and the fix check adds at least one round on top.

    A raise is also the only way to resume from a budget stop. PKT-6's decision 10d says a ceiling raised in the config isn't an answer on its own. The numbers were checked offline with the merged `credit-check.ps1` and a stubbed `gh`. On the template's rates, an S packet starts at 318. Round 1 at tier 2 with two lenses prints `so-far=130 step=238`, so the raise is 408. The fix check after it prints `OVER so-far=408 step=210 total=618 ceiling=408 (raised by …)`, and round 1's own check is `WITHIN … total=368 ceiling=408`. With four lenses in two runs, the same rule gives 496, and so-far is 496.
15. **The packet's steps run in this order: 4 (budget half), 1, 2; then 5, 1, 3.** Packet A takes the `next=round` stop and the refused settle (S12.1, S12.2), then the raise into the window (S12.3), the `next=fix` stop (S12.4), and the raise and resume (S12.5). Packet B takes the untrusted raise at its `next=round` stop (S12.6, S12.7), then the window again (S12.8) and the settle (S12.9). The untrusted raise goes before B's own raise. A trusted raise posted earlier would decide the ceiling whatever the untrusted one says, and the check would prove nothing.
16. **The untrusted raise is judged on three readers:** `board rounds` doesn't list it; `credit-check` with round 1's own arguments (from review-scope at the stop's head) still prints `(config)` and exits 3; and the resume leaves no new `packet:needs-human` comment. A resume with no answer releases and stops without a comment (packet-dispatch, **After a stop**), and the stop's `CreatedAt` shows that.
17. **Every check names the marker it reads:** `packet:needs-human reason=budget …` or `reason=model-tier …` (through `board marker … needs-human -Json`), `packet:budget max=…` (the `budget` rows of `board rounds`), `packet:settle head=…` (`settle-request`, `(used)`), `packet:settle-check head=…`, `packet:round …` and `packet:handoff …`.

## Where the packet and the merged code differ

The merged code wins in each case.

- **The ceiling in step 1** is set with a raise, not a config value (decision 14). The packet's own words still hold for where the stop lands.
- **A refused settle** gets an answer on the item: the stop's own first line, repeated (PKT-6, decision 11). A settle after a model-tier stop is refused the same way, and the item stays Needs human (decision 12 there). S11.10 and S12.2 check that comment.
- **A model-tier resume** needs no marker from the owner. The owner's answer is a session on the dearer model, so S11.11 only checks that the round ran again.
- **`board rounds`** prints a raise as `budget <round> max=<n> by <login>`, with round `0` before any round report (`Get-PwGhRounds`). It prints a used settle with `(used)`.
- **`credit-check`'s** text line is `OVER so-far=… step=… total=… ceiling=… (config | config on origin/<branch> | raised by <login> <date>)`, and the stages quote it as merged.

No command, flag or marker in the packet is missing from `main`.

## What was checked offline, and what only H-4 can check

Checked offline, on scratch repositories, against `main`:
- `install.ps1 -PlanOnly`: the `-DryRun` and real file lists, the summary lines, `"mode": "plan-only"`, a second run's `17 file(s) already up to date`, and the refusal on a full install;
- `-Profile solo` on a fresh repository: the six values, the `Agent classes` line, and no warning;
- `-Profile solo` again on that config (`already has the solo profile's settings`), and on a default config (the list of differing settings);
- the Local harness warning's text with a dearer model first in `models.strong`;
- `credit-check.ps1`'s numbers for every stop in stage 12, with a stubbed `gh`: start, a `next=round` stop, the window, the `next=fix` stop, a second raise, and an untrusted raise that changes nothing.

Only a live run can check the rest:
- what the coding agent and GitHub do to the board;
- how a host refuses a reviewer, and whether it falls back;
- whether Copilot CLI's limit counts subagents;
- whether a model follows the stops, resumes and settles;
- what the credits really are.

## Tests

18. **No test was added.** The packet's Owns has no test file, and `tests/run-tests.ps1` is PKT-7's. The two existing assertions that read the e2e prompt still find the guard headings and the stop line that S1.4, S8.7 and S8.8 quote, and those stages are unchanged. The suite passes: 623 passed and 0 failed, both before and after this change.

## Pointers for PKT-8 or a later change

- The README's paragraph on `tests/copilot-e2e.prompt.md` (*Inside Copilot*) lists the stages up to "safety probes, and ends with a report". It could add: "Stages 10 to 12, in sandboxes of their own, check a plan-only hand-off to the coding agent, the solo profile with a refused reviewer, and the credit ceiling's stops, raises and settles, and record what each cost."
- Known limitations and the Models bullet should take H-4's answers (S11.6, S11.9) once it has run, as H-4's checklist says.
