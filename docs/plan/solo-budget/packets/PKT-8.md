# PKT-8 · Document plan-only mode, the solo profile and the ceiling

- **Packet:** PKT-8 · **Priority:** P1 · **Size:** M · **Wave:** W3 · **Workstream:** Docs · **Target:** 2026-11-16
- **Depends on:** PKT-2, PKT-4, PKT-6, PKT-7
- **Review lenses:** security, correctness
- **Locks:** none
- **Initial status:** Ready

## Goal

The README and the cost page say what the phase built and what it trades. They cover the three new keys, the amended tier floor in the safety model, the Local harness's cost-tier rule, the ceiling's Needs human and resume path, and what a solo seat buys. Each claim must be true of the merged code.

## Spec

- README.md: the ideas list, Configure, Use, Copilot specifics → Models, Safety model and Known limitations.
- docs/cost.md as PKT-7 left it.
- The decision records of PKT-1 to PKT-7.

## In scope

- **README, Configure:** rows for `review.tierCap`, `models.agents` and `budget.maxCreditsPerPacket`. The `review.maxRounds` row says the solo profile uses 2.
- **README, the ideas list:** "at most `review.maxRounds` (3) rounds".
- **README, Safety model:**
  - **A new row, "The review tier is a floor".** review-scope measures it from the diff, with the config and packet file at the base. The panel may raise it and never lower it, and a later round is never below the one before. With `review.tierCap`, the measured raises stop at the cap. These still raise to tier 3:
    - review machinery;
    - a `.gitattributes` change;
    - a diff of only generated or lock files;
    - `review.deepPaths` and `review.maxPaths`;
    - the packet's **Review tier** line.

    A branch can't set the cap, and a config change is machinery.
  - **Amended: "A packet branch can't weaken its own review".** The cap and the ceiling come from the config at the base. A raise counts only as a trusted `packet:budget` comment.
  - **Amended: "A failed check never counts as a pass".** A credit check that exits 2 stops the dispatch, and a reviewer the host refuses stops the round with no report.
- **README, Copilot specifics → Models.** This replaces "run the dispatcher on a model at least as capable as packet-reviewer-deep's". In the Local harness, a subagent whose model is in a higher cost tier than the session's doesn't run. The kit then stops the round at Needs human, and the installer warns about the setups where that can happen.
- **README, Use:** the Needs human kinds for the budget and for a refused reviewer, and the settle that passes a round's findings as follow-ups after a budget stop before a fix.
- **README, Known limitations:**
  - the ceiling is an estimate, and resume sessions and CI-fix runs leave no marker;
  - any trusted identity can post a `packet:budget` raise, the dispatcher's own included, as it can a settle;
  - a coding-agent hand-off skips the brief and the panel, and the scope check runs only when someone runs it.
- **docs/cost.md, a "Solo profile" section:**
  - its config;
  - typical and expected credits per S, M and L packet;
  - the 10-packet phase;
  - packets a month for a Pro, Business and Enterprise seat, with the range;
  - what a packet forced to tier 3 adds;
  - what the profile trades.
- **Copilot CLI's session limit.** Copilot CLI and the Copilot SDK can cap a session's real spend: `/limits set max-ai-credits <n>`, or `copilot -p … --max-ai-credits <n>` (public preview, soft, at least 30). It stops mid-step, where the kit's ceiling stops between steps on an estimate. Document it as a backstop set above the ceiling. Whether it counts the subagents' credits isn't known until H-4 runs PKT-9's S11: say so, and H-4 updates the line.
- **docs/cost.md, elsewhere:**
  - "The tier is a floor" among the four properties, amended as above;
  - lean change #8 marked as built.

## Out of scope

- `CHANGELOG.md`, `VERSION` and the README's install tag (H-3).
- The e2e prompt (PKT-9).

## Owns

- `README.md`
- `docs/cost.md`
- `tests/cases/cost-doc.tests.ps1`
- `docs/decisions/solo-budget/PKT-8.md`

## Shared touchpoints

- none

## Consumes

- `install.ps1 -PlanOnly`, the plan-only quick-start and the manifest's `mode` (PKT-2).
- `-Profile solo` and `models.agents` (PKT-4).
- The Needs human markers and the narrow settle (PKT-6).
- The three-tier cost page (PKT-7).

## Provides

- The README and cost page that H-3 releases.

## Acceptance criteria

- [ ] Each new key has a Configure row whose default and limits match `Get-PwConfig`, `Get-PwCreditCeiling` and `Get-PwAgentModelClass`.
- [ ] The safety table has the "review tier is a floor" row, with the full forced list as review-scope implements it, and both amended rows.
- [ ] The Models bullet states the Local cost-tier rule, what the kit does about it and what the installer warns, and no longer tells the owner to raise the dispatcher's model as the only fix.
- [ ] The solo section's per-packet figures equal `Get-PwCreditEstimate` within 1% for the shapes it states, on the default `creditsPerRun` the solo overlay inherits. It gives packets a month for 1,500, 1,900 and 3,900 credits. PKT-7's `tests/cases/cost-doc.tests.ps1` is extended to read the solo table and check it the same way.
- [ ] Every command and key the docs name exists at the head; the owner checks this in review, since the phase isn't dispatched.

## Tests to run

- `pwsh -NoProfile -File tests/run-tests.ps1`

## Decision record

`docs/decisions/solo-budget/PKT-8.md`

## Dispatcher notes

Write it as the README is written: plain sentences, the reason after the rule, no marketing. Cite the seat figures from GitHub's docs. Individuals: "Usage-based billing for individuals" (`/copilot/concepts/billing-and-usage/individuals/billing`): Pro 1,500 a month, as 1,000 base credits plus a 500 flex allotment that GitHub says can change; Pro+ 7,000; Max 20,000. Allowances reset at 00:00 UTC on the 1st and don't carry over. Business 1,900 and Enterprise 3,900 come from the organizations page cost.md already cites. GitHub's docs also carry promotional figures for Business and Enterprise (3,000 and 7,000): check their terms before quoting them.
