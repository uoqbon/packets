# PKT-7 · Recalculate the cost page and default rates for three tiers

- **Packet:** PKT-7 · **Priority:** P0 · **Size:** M · **Wave:** W1 · **Workstream:** 4 Calibration · **Target:** 2026-11-09
- **Depends on:** PKT-1
- **Review lenses:** correctness, tests
- **Locks:** none
- **Initial status:** Ready

## Goal

docs/cost.md's figures were worked out for four review tiers, with the strong class on Opus 5.5 rates, and the page says its tables haven't been recalculated. The template has since put GPT-6.1 Sol first in every class (0.1.0, #2), at Sonnet 5.5's rates.

This packet recomputes every table for the three-tier panel on GPT-6.1 Sol in every class (the owner's decision), with tier 3 at the old tier 4's shape. It also moves the default `budget.creditsPerRun` to the same rates, so that the page, `progress.ps1 -Credits` and the credit ceiling price a packet the same way. Finally, it pins the page's headline numbers to the estimator, so they can't drift apart again.

## Spec

- docs/cost.md: the "Written for four review tiers" paragraph and every table below it.
- `Get-PwCreditEstimate`, which the page says reproduces its typical packets within 1%.
- The rates table in docs/cost.md: GPT-6.1 Sol costs the same as Claude Sonnet 5.5, half of Claude Opus 5.5 on every token type.

## In scope

- **The rates.** `budget.creditsPerRun` in `templates/packet-workflow.json` and in `$script:Defaults`, put on GPT-6.1 Sol by the rate table's 2:1 ratio and rounded to whole credits:

  | Rate | Today | New |
  | --- | --- | --- |
  | `dispatcher` | 50 | 25 |
  | `dispatcherPerRound` (S, M, L) | 300, 330, 390 | 150, 165, 195 |
  | `dispatcherPerReviewerRun` | 35 | 18 |
  | `reviewerByTier` tier 3 (S, M, L) | 195, 280, 380 | 98, 140, 190 |

  `implementer`, `implementerFix`, tiers 1 and 2, and `laterRoundFactor` were already priced at Sonnet rates, so they stay. Tiers 1 and 2 now run at low and medium effort, below the reasoning their rates were worked out at, so the page keeps their token shapes as written and calls those two rates upper bounds until H-2 measures them. An existing config keeps the values written in it: the installer never rewrites a config.
- **The tests that pin today's rates.** Re-pin the credit figures in `tests/run-tests.ps1` (the stage 5 estimate, the grouped run, the summary, the four-tier list and the `progress -Credits` end-to-end lines) to the new rates. The decision record derives each new number by hand.
- **Finished packets in `progress.ps1 -Credits`.** `Get-PwCreditSummary` counts a packet as finished when a `settle-check` follows its last round, as well as when that round passed or went to the owner. A settle after a budget stop (PKT-6) leaves the last round at `outcome=fix`.
- **The page.** Recompute, or mark as history, each of these in docs/cost.md:
  1. **In short**: the per-packet figures (1,900 / 3,500 / 6,300), the 3,700 average, and "3", "5" and "7 to 8" packets a month.
  2. **Rates for the models in `models`**: the Kit class column, which says GPT-6.1 Sol is first in every class.
  3. **Runs per packet, by role**: the Reviewers row, which reads "tiers 3 and 4: strong".
  4. **The token shapes assumed per run**: the tier-4 and tier-3/2/1 rows become tier 3 (high effort, the old tier 4's shape), tier 2 (medium) and tier 1 (low).
  5. **Credits per run that follow from these shapes**: four reviewer rows become three, and the strong-class rows are halved.
  6. **The tier rules under "One packet"**: S starts at 2, M at 3, L at 4, plus one per fixed round. These become S 2 → 3 → 3, and M and L at 3 throughout.
  7. **Credits per packet under the defaults**: all eight rows. "Stage 5 as run" stays as run, relabelled at tier 3.
  8. **The Stage 5 calibration paragraph**: its tier path, its 800-credit and 28% figures, and the 2,858 / 2,870 comparison.
  9. **Where the credits go in a typical M packet**: the shares, and "of 87 runs, 52 at tier 4, 26 at tier 3 and 9 at tier 2".
  10. **One phase and one month**: the 5-, 10- and 20-packet rows, `packet-plan` at Sonnet rates, and "about 3,660 credits … 3.4 packets".
  11. **The four lever tables** (Free, Good trades, Mixed, Poor trades): every Saves figure against the recalculated 10-packet phase. Reword the rows that name tier 4 or the old tier 3, and the two whose saving comes from leaving the strong class: "Dispatcher on the standard class" and "Deep (tier 3) reviewer on the standard class". Both save nothing while every class lists the same models.
  12. **The kit-changes table (#1 to #7)**: its Saves column.
  13. **The lean profile table (#8, #9)**: its "Saves on top" column.
  14. **The Results table** (Default, Budget, Lean): every row, packets a month included.
  15. **"Applied in order"**: the 5,800, 6,300 and 800.
  16. **Running it within the pool**: 2,400 a packet, US$240, about 4,000 for an L packet, 350 overhead, and "1.8× an M one".
  17. **Calibrate step 1**: "Opus 5.5 tokens … eight tier-4 reviewer runs" now describes a run on other models; mark it as history.
  18. **Recommended budget profile**: the `creditsPerRun` its JSON restates (0.1.1's), and "Leave `budget.creditsPerRun` out to use the defaults shown", which must show the new defaults.
- **On the page, also:**
  - Remove the "Written for four review tiers" paragraph.
  - State once that the page assumes GPT-6.1 Sol in every class, and add one sentence saying that a dearer strong class (Opus 5.5, GPT-5.6 Sol) doubles the dispatcher's and tier 3's parts.
  - Leave the 73-packet table as it is: it records history.

## Out of scope

- The solo profile section and the per-seat table (PKT-8).
- Measured rates (H-2).

## Owns

- `docs/cost.md`
- `templates/packet-workflow.json`
- `skills/packet-board/scripts/PacketWorkflow.ps1`
- `tests/run-tests.ps1`
- `tests/cases/cost-doc.tests.ps1`
- `docs/decisions/solo-budget/PKT-7.md`

## Shared touchpoints

- none

## Consumes

- `Get-PwCreditEstimate` and `$script:Defaults.budget.creditsPerRun`, as PKT-1 leaves them.
- The `tests/cases/` folder from PKT-1: the new test only dot-sources `PacketWorkflow.ps1`, so it needs no case repository.

## Provides

- The default `budget.creditsPerRun` on GPT-6.1 Sol rates, which the solo overlay (PKT-4) inherits.
- A three-tier cost page that PKT-8 adds the solo profile to.

## Acceptance criteria

- [ ] `budget.creditsPerRun` in the template and in `$script:Defaults` holds the new values above, and nothing else changes in either file but `Get-PwCreditSummary`'s finished rule.
- [ ] A packet whose last round says `outcome=fix` and whose rows end with a `settle-check` counts as finished in `Get-PwCreditSummary`.
- [ ] The only existing tests that change are the credit figures named above, and the decision record derives each new figure by hand.
- [ ] Each of the 18 items above is recomputed for tiers 1 to 3 on GPT-6.1 Sol, or marked as history; the "Written for four review tiers" paragraph is gone, and no table has a tier-4 row.
- [ ] A test reads the S, M and L typical totals from "Credits per packet under the defaults", and matches each within 1% to `Get-PwCreditEstimate` on the default rates for the shapes the page states, plus the resume share it states.

## Tests to run

- `pwsh -NoProfile -File tests/run-tests.ps1`

## Decision record

`docs/decisions/solo-budget/PKT-7.md`

## Dispatcher notes

On the new rates the estimator gives these typical three-tier packets: S about 1,180, M about 2,160 and L about 3,430. That is about 2,160 a packet all in, with `packet-plan` at Sonnet rates (about 275 for 10 packets). The 0.4-per-extra-lens factor stays as it is until H-2 measures it.

The owner approved the rate change and the re-pinned tests on 2026-10-31. The changelog entry (H-3) must say that new installs estimate about half what 0.1.1 did, and that an existing config keeps its own rates until the owner copies the new ones.
