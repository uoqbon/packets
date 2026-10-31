# PKT-9 · Add e2e stages for plan-only, solo and the ceiling

- **Packet:** PKT-9 · **Priority:** P1 · **Size:** S · **Wave:** W3 · **Workstream:** Docs · **Target:** 2026-11-16
- **Depends on:** PKT-2, PKT-4, PKT-6
- **Review lenses:** correctness, tests
- **Locks:** none
- **Initial status:** Ready

## Goal

The offline tests can't see three things: how a host treats a reviewer above the session's cost tier, how the Copilot coding agent and the Azure Boards integration leave the board, and how a model follows the new stops. `tests/copilot-e2e.prompt.md` gets stages that check each of them on a sandbox and record what they cost.

## Spec

- `tests/copilot-e2e.prompt.md`: its stage format, its `.packet-e2e/` state, and its report.

## In scope

- **S10 Plan-only.**
  1. In a second sandbox, run `install.ps1 -PlanOnly` and check the file list.
  2. Run `/packet-plan` on the mini spec, then `board setup` and `sync`.
  3. Hand one packet to the coding agent by assigning its issue to Copilot.
  4. Record the board status before the hand-off, while the agent works and after the merge, and whether its PR closes the issue.
  5. Run `board reconcile`.
- **S11 Solo.**
  1. On a fresh sandbox with no config yet (`-Profile` chooses the template for a new config only), run `install.ps1 -Profile solo`, then one dispatch end to end.
  2. Record its rounds, its tiers (capped from what) and its credits from the AI usage report.
  3. In the Local harness, set `models.strong` to a model dearer than the dispatcher's.
  4. Run a packet whose diff matches `review.deepPaths`. Expect Needs human with `reason=model-tier`, and record the host's message.
  5. Resume from a session on the strong model.
  6. Note whether a prioritized `model:` list falls back to a cheaper entry instead of refusing (risk 5).
  7. From Copilot CLI, set a session limit (`/limits set max-ai-credits <n>`) on a dispatcher session, and record whether the implementer's and reviewers' credits count toward it.
- **S12 Ceiling.**
  1. Set `budget.maxCreditsPerPacket` between the estimate after round 1 and that plus the cheapest round after a fix, so the stop comes before the fix run. Expect `reason=budget next=fix`.
  2. Post `packet:budget max=` from the owner and resume.
  3. Repeat, and answer with a settle that passes round 1's findings as follow-ups; check the follow-up issues and the settle-check.
  4. Check that a settle is refused after a `reason=budget next=round` stop (a ceiling between the `-Next start` price and round 1's price, so the stop comes before round 1) and after a `reason=model-tier` stop (S11 step 4).
  5. Check that a `packet:budget` from a second, untrusted account is ignored.
- Each stage states its expected credits up front, from the cost page.

## Out of scope

- The Azure story prompt (`tests/copilot-e2e-azure-story.prompt.md`). An Azure coding-agent hand-off stage is a follow-up.
- Running the stages: H-4.

## Owns

- `tests/copilot-e2e.prompt.md`
- `docs/decisions/solo-budget/PKT-9.md`

## Shared touchpoints

- none

## Consumes

- `install.ps1 -PlanOnly` and `-Profile solo` (PKT-2, PKT-4).
- The `reason=budget` and `reason=model-tier` markers and the resume paths (PKT-6).

## Provides

- Stages S10 to S12 in the e2e prompt.

## Acceptance criteria

- [ ] S10, S11 and S12 follow the prompt's existing stage format: steps, the checks each records, and where they stop for the owner.
- [ ] S11 records the host's answer to a refused reviewer verbatim, and whether a prioritized `model:` list fell back to a cheaper model.
- [ ] S12 covers raise, settle and the untrusted raise, and each check names the marker it reads.
- [ ] Each stage gives its expected credits.
- [ ] The existing tests that read the e2e prompt (the guard headings it quotes) still pass.

## Tests to run

- `pwsh -NoProfile -File tests/run-tests.ps1`

## Decision record

`docs/decisions/solo-budget/PKT-9.md`

## Dispatcher notes

Don't renumber the existing stages: the README and the tests refer to S1.4, S8.7 and S8.8.
