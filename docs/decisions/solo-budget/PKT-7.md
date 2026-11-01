# PKT-7 · Decision record

Choices [PKT-7](../../plan/solo-budget/packets/PKT-7.md) left open, and why each went the way it did. The owner approved the rate change and the re-pinned tests on 2026-10-31.

## The rates

1. **The new defaults are the packet's table, unchanged.** `dispatcher` 25, `dispatcherPerRound` 150 / 165 / 195, `dispatcherPerReviewerRun` 18 and tier 3 of `reviewerByTier` 98 / 140 / 190. Each is the 0.1.1 value halved and rounded to a whole credit, half up (17.5 → 18, 97.5 → 98). `implementer`, `implementerFix`, tiers 1 and 2 and `laterRoundFactor` stay. They change in the template and in `$script:Defaults`, and nowhere else in either file. An existing config keeps the `creditsPerRun` written in it, because the installer never rewrites a config. Only a config that leaves `creditsPerRun`, or part of it, out gets the new values.
2. **The merged code's names are the packet's.** `Get-PwCreditEstimate`, `Get-PwCreditSummary` and `$script:Defaults.budget.creditsPerRun` are as PKT-1 left them, so nothing was renamed. The case file runs kit code through `Invoke-CaseProbe`, as the Consumes line updated in #31 says.

## Finished packets

3. **"A settle check follows its last round" means: walking back from the newest marker row, a `settle-check` comes before any round report.** Get-PwCreditSummary already gets every trusted marker row from `Get-PwGhRounds`, oldest first, with settle rows included. A packet is finished when that rule holds, or, as before, when its last round passed or went to the owner. A settle request alone doesn't finish a packet: only the owner's settle check does. A round reported after a settle check (the packet reopened) makes the packet unfinished again. The estimate itself is unchanged: settle rows still cost nothing.

## The re-pinned tests

4. **Eight assertions in `tests/run-tests.ps1` change, and only their credit figures.** Base for S is 25 + 105 = 130, and for M it is 25 + 200 = 225. A round costs `dispatcherPerRound` + 18 × runs + the reviewers + `implementerFix` on a fix round. A reviewer run costs its tier's rate, times 0.85 from round 2 on. A tier-4 marker is priced at tier 3.

   | Test | Old | New | Derivation on the new rates |
   | --- | --- | --- | --- |
   | credit estimate for stage 5 | 2858 | 1529 | 130 + (150 + 4×18 + 4×98 + 40 = 654) + (150 + 3×18 + 0.85×3×98 + 40 = 493.9 → 494) + (150 + 18 + 0.85×98 = 251.3 → 251) |
   | two runs of two lenses count 2.8 runs | 1071 | 590 | 130 + 150 + 2×18 + 98 × 2.8 (274.4) = 590.4 |
   | credit summary | summary 4781, avg 2858, month 3516, left 8984, more 3 | 2647, 1529, 1886, 10614, 6 | PKT-02 (M): 225 + (165 + 2×18 + 2×140 + 55 = 536, September) + (165 + 18 + 0.85×140 + 55 = 357, October) = 1118. Total 1529 + 1118 = 2647. Only PKT-01 has finished: average 1529. October: 1529 + 357 = 1886. Left 12500 − 1886 = 10614. More: ⌊10614 / 1529⌋ = 6 |
   | four-number reviewerByTier | 1923 | 1517 | [30, 70, 160, 280] keeps 280 at tier 3: 225 + (165 + 36 + 2×280 + 55 = 816) + (165 + 18 + 0.85×280 + 55 = 476) |
   | progress -Credits, JSON | PKT-01 2183, PKT-02 768, total 2951, average 2183, October 1371 | 1221, 561, 1782, 1221, 863 | PKT-01 (M): 225 + (165 + 3×18 + 3×140 + 55 = 694, 30 September) + (165 + 18 + 0.85×140 = 302, October). PKT-02 (M): 225 + (165 + 18 + 70 × 1.4 + 55 = 336) = 561. October: 302 + 561 = 863 |
   | progress -Credits, 30 September | 1580 | 919 | 225 + 694 |
   | progress -Credits under th-TH | 1371 | 863 | as the JSON line |
   | progress -Credits text | 768, phase 2,951, 2,183 | 561, 1,782, 1,221 | as the JSON line |

   Every other base test passes unchanged. The two comment lines above the stage 5 and summary assertions carry the new arithmetic.

## The page

5. **Every figure comes from the per-run table by one method.** The dispatcher's and tier 3's runs cost half of their 0.1.1 values: tier 3 has the old tier 4's shape, and GPT-6.1 Sol costs half of Opus 5.5 on every token type. Tiers 1 and 2, the implementer and the board and progress sessions keep their figures. The typical packets are S 585 + 400 + 185 + 20 = 1,190, M 680 + 1,155 + 310 + 20 = 2,165 and L 820 + 2,080 + 505 + 20 = 3,425. Those parts are the three-round dispatcher, the reviewers (rounds 2 and 3 at 0.85), the implementer and fixes, and half a 40-credit resume session. The estimator gives 1,188, 2,167 and 3,432 once the resume share is added: the packet's "about 1,180, 2,160 and 3,430". The one-round dispatcher for L is 575 / 2 = 287.5, which the page shows as 290. Figures in that table are rounded to the nearest 5, so every row's parts add up to its total exactly.
6. **The tier paths follow review-scope.ps1 as merged.** S starts at tier 2, and M and L start at tier 3, the top. The +1 rule stops at 3, so the paths are S 2 → 3 → 3 and M and L 3 → 3 → 3. Best cases: S 1 (2), M 1 (3), L 1 (3). Stage 5 "as run" keeps its rounds, lenses and runs, relabelled at tier 3. Without `ci.yml` its path is 2, 3, 3. The CI file now costs 1,530 − 1,340 = 190 credits, 12%.
7. **The phase overhead is `packet-plan` plus four board or progress sessions.** `packet-plan` is halved to 200 / 275 / 450. Four board or progress sessions at 15–20 each make about 75 for every phase size. This replaces 0.1.1's unexplained 50 / 50 / 100 and gives the review notes' "about 350" for a 10-packet phase. The phase is 3 × 1,190 + 5 × 2,165 + 2 × 3,425 + 350 = 21,595, shown as 21,600. That is 2,160 a packet all in, and 12,500 / 2,160 = 5.8 packets a month.
8. **The ranges divide by 1.75 and 0.6, in every column.** 0.1.1's Results table had upper bounds that don't follow from that rule: Budget 5.3 gave 8.8, not 10, and Lean 7.6 gave 12.7, not 15. The new ones do: Default 5.8 (3–10), Budget 8.9 (5–15), Lean 8.9 (5–15).
9. **How each lever's saving is recomputed.** The page doesn't show the token model behind its lever savings, so each one is recomputed by the most direct rule its mechanism allows:
   - **Levers that change rounds, lenses or tiers** (should-fix pass, maxRounds 2, two lenses per run, the lens caps, no +1, the tier-3 threshold) are recomputed from the per-run table. Their dispatcher part is priced at the new default `dispatcherPerRound` and `dispatcherPerReviewerRun`, which reproduce the page's three-round dispatcher within 1%. Some examples:
     - Should-fix pass: 44/53 of dropping round 3 and the second fix, (3 × 291.3 + 5 × 494 + 2 × 808.5) × 0.83 = 4,118, so 19% (4,100). On 0.1.1's figures the same method gives 2,107 for "no +1", where the page said 2,100.
     - No +1: S packets only, (98 − 50) × 0.85 × (2 × 44/65 + 44/65 × 44/53) × 3 = 234.
     - Tier-3 threshold: an M packet's round 1 at tier 2, 5 × 4 × (140 − 70) = 1,400.
   - **Levers that cut tokens in every run** (MCP servers off, prompts that name files) keep their 0.1.1 share of the phase: 14% (3,100) and 3% (700).
   - **Levers on the dispatcher alone** (`maxParallelLenses`, a fresh session per round, the resume session in "hold the panel") are halved: 350 or 550 (366 and 549, rounded to 50), 800, and 40.
   - **Levers whose saving came from leaving the strong class** save nothing while every class lists the same models. These are the dispatcher and tier 3 on the standard class, lean change #8 and `packet-plan` on the standard class. Each row now says what it would save with a dearer strong class.
   - **The standard-fallback row** is done (0.1.0). The roles it covers didn't change price, so GPT-5.6 Sol would still add about 6,100, now 28% of the phase.
   - **The implementer on Haiku** keeps its 2,600: the implementer's rates didn't change.
10. **The budget profile is the three steps in order, on these figures.**
    - Step 1: two lenses per run, 3,479.
    - Step 2: should-fix pass from round 2, with round 3's lenses grouped, 44/53 × 4,284 = 3,557.
    - Step 3: prompts, 3.14% of what is left (0.1.1's 1,150 / 36,600), 458.
    - That leaves 14,106. Per packet: S 806, M 1,401, L 2,171. Stage 5 as run: 1,530 − 221.6 − 241.8, less 3.14%, is 1,033.
    - The lean profile adds #9 alone, because #8 saves nothing on one model. #9 saves 110 a phase, on S packets only: (98 − 50) × 1.4 × 0.85 × 44/65 a packet. Stage 5 keeps tier 3 under the lean profile, because `ci.yml` forces it.
11. **The page says what the lean profile is now worth.** On one model it saves about 1% more than the budget profile, so the page says it is worth its trade-offs only with a dearer strong class. That follows from the owner's decision to put GPT-6.1 Sol in every class. It isn't a recommendation to drop the profile.
12. **History stays history.**
    - The 73-packet table is untouched.
    - The rates table marks Opus 5.5, GPT-5.6 Sol and GPT-5.6 Luna as the classes they held before 0.1.0.
    - "Two things in the template" now reads as what 0.1.0 fixed.
    - Calibrate step 1 says the stage 5 run was on other models and the four-tier panel. It can calibrate token shapes, not today's rates.
    - The kit-changes table's "four reviewer agents" is left as written, because it describes that change as made.
    - The 2,858 / 2,870 comparison keeps its old figures as 0.1.1's. The new one is 1,529 / 1,530, from the same markers.
13. **The token-shape rows.** Tier 3 (high effort) keeps the old tier 4's shape. Tiers 2 and 1 (medium and low) keep their old shapes. The page calls those upper bounds, since those shapes were worked out at more reasoning than these efforts use. The old tier 3 shape (Opus, medium) is gone with its tier.

## Tests

14. **`tests/cases/cost-doc.tests.ps1` reads the page, not a copy of it.** It parses every row of "Credits per packet under the defaults": tiers, lenses per round, the parts, the resume share and the total. It builds round markers from each row, with a fix after every round but the last, and prices them with `Get-PwCreditEstimate` on the defaults through `Invoke-CaseProbe`.
    - Typical and stage 5 rows must match within 1%, with the resume share added. Best cases must match within 10%, the tolerance the page states.
    - Each row's parts must add up to its total.
    - The typical totals must be the planned three-tier figures (within 15 credits of 1,180 / 2,160 / 3,430).
    - The phase table must follow from the typical rows and the overhead rule. Per packet all in, and packets a month, must follow from the 10-packet total.
    - The `creditsPerRun` in the defaults, the template and the page's budget-profile JSON must be the packet's values.
    - No table may have a tier-4 row or a round path through tier 4. The "Written for four review tiers" paragraph must be gone, and the page must state its model assumption.
    - The phase table must have its three rows, and the budget-profile JSON is read from under its own heading, so a JSON block PKT-8 adds earlier on the page can't be compared by mistake.
    - The "In short" bullets must give the table's typical totals, the per-packet figure, the packets a month and the months per 10-packet phase.
    - The finished rule has its own test, with eight packets: settled; a settle request only; reopened after a settle (with a round that has a `Kind`, and with one that has none); a second settle request after the check; still fixing; passed; and gone to the owner.

    Against 0.1.1's page, 19 of the case file's 33 checks fail. The tests review's mutations (a changed rate in each of the three sources, the old finished rule, a settle request counted as a settle, a dropped Kind-less branch, a tier-4 path, a drifted typical total, wrong "In short" figures, a removed phase row) each fail at least one check. Not covered: `progress.ps1 -Credits` end to end with a settle check, because the progress fixture in `tests/run-tests.ps1` has none, and adding one would change an existing test beyond its credit figures. The acceptance criterion names `Get-PwCreditSummary`, which progress.ps1 calls with every trusted marker row. The PKT-1 grep (no `$script:` assignment, no dot-sourced kit script) covers this file too.

## Changelog wording for H-3

This doesn't go in `CHANGELOG.md` here: VERSION and the changelog belong to the release (H-3). Proposed entry:

> - **Default credit rates on GPT-6.1 Sol.** `budget.creditsPerRun`'s defaults now price the dispatcher and tier 3 at GPT-6.1 Sol's rates, half of Opus 5.5's: `dispatcher` 25, `dispatcherPerRound` 150 / 165 / 195, `dispatcherPerReviewerRun` 18, and tier 3 of `reviewerByTier` 98 / 140 / 190. New installs, and configs that leave `creditsPerRun` out, estimate about half what 0.1.1 did. An existing config keeps the rates written in it (the installer never rewrites a config) until you copy the new ones from [docs/cost.md](docs/cost.md#recommended-budget-profile) or the template.
> - **`progress.ps1 -Credits` counts a settled packet as finished** when the owner's settle check follows its last round, even if that round asked for a fix.
> - **docs/cost.md is recalculated for three tiers on GPT-6.1 Sol:** about 1,190 (S), 2,165 (M) or 3,425 (L) credits a typical packet, 2,160 a packet over a phase, and about 6 packets a month on 12,500 credits, or 9 under the budget profile.

## Not changed

- The 0.4-per-extra-lens factor stays until H-2 measures it.
- The solo profile and the per-seat table are PKT-8's. Measured rates are H-2's.
- `VERSION` and `CHANGELOG.md` are untouched.
