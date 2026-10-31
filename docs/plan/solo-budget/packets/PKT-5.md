# PKT-5 · Check a packet's estimated credits against a ceiling

- **Packet:** PKT-5 · **Priority:** P0 · **Size:** M · **Wave:** W1 · **Workstream:** 3 Credit ceiling · **Target:** 2026-11-09
- **Depends on:** PKT-1
- **Review lenses:** security, integration, correctness, tests
- **Review tier:** 3
- **Locks:** none
- **Initial status:** Ready

## Goal

Before a review round or a fix run, a script tells the dispatcher whether the packet's estimated credits so far, plus that step, stay within `budget.maxCreditsPerPacket`. It prices them with the same estimator and the same trusted round markers as `progress.ps1 -Credits`. So a packet stops before it overspends, and an estimate that fails never reads as "within".

## Spec

- Workstream 3 of the source request.
- `Get-PwCreditEstimate` and `Get-PwRoundRows` in `PacketWorkflow.ps1`, and `Get-PwGhRounds` in `providers/github-common.ps1`.
- The settle marker in `skills/packet-dispatch/SKILL.md` (**Settle**), which the raise marker follows.

## In scope

- **`skills/packet-dispatch/scripts/credit-check.ps1`:**

  ```text
  credit-check.ps1 -Packet <ID> -Base <ref> [-Head HEAD] -Next start|round|fix [-Pr <n>]
                   [-Round <N> -Tier <t> -Lenses <a,b,c> -Runs <n>] [-Json]
  Exit codes: 0 OFF or WITHIN · 3 OVER · any other code an error (stop; never a pass). OVER isn't 1 because `pwsh -File` exits 1 on a parameter-binding error.
  ```

  - **What it reads.** The config and the packet file at the merge base of `-Base` and `-Head`, as review-scope does. The ceiling comes from `Get-PwCreditCeiling` for the packet's size. Markers and raises are read with the trusted authors of the config on origin's default branch (`Get-PwSharedConfig`), as `board rounds` reads settles.
  - **Ceiling unset.** It prints `OFF` and exits 0 after reading only the config at the base: no packet file, PR, board or `creditsPerRun`. An install that sets no ceiling then meets no failure that review-scope's own config read wouldn't already hit.
  - **So far.** `Get-PwCreditEstimate` over the PR's trusted round markers (`Get-PwGhRounds`).
  - **`-Next round`** prices the round review-scope chose: its tier, its lenses and its runs. `-Round` must be one more than the last round marker.
  - **`-Next fix`** adds nothing for the fix itself, since the last round's `outcome=fix` already prices `implementerFix`. It adds the cheapest round that must follow the fix: the last round's confirmed lenses, at its tier plus one (review-scope raises a round after fixed findings) up to `review.tierCap` or 3, at the later-round factor. After a round that passed (§9.3's CI fix), it prices `implementerFix`, which no marker will book, plus a one-lens round at that round's tier.
  - **`-Next start`** runs before a claim, with no PR. It prices the base plus a one-lens round at tier 1, so a ceiling no packet of that size can meet stops the packet before anything runs.
  - **A raise.** The newest trusted PR comment `` `packet:budget max=<credits>` `` raises the ceiling for the rest of this packet (owner's decision, question 5). A raise only ever raises. A trusted raise whose `max` isn't a whole number above 0 is an error.
  - **Output.** `WITHIN so-far=<n> step=<n> total=<n> ceiling=<n> (config | raised by <login> <date>)` exits 0. `OVER` with the same fields exits 3. Any error (config, packet, markers, `gh`, estimator) exits 2 with a message, never WITHIN. The field is `step=`, as in the Needs human marker, where `next=` names the step (`round` or `fix`).
- `github-common.ps1`: `Get-PwGhRounds` also returns `budget` rows, from trusted authors only. They have the same properties as settle rows: `Tier`, `Lenses`, `Runs` and `Confirmed` set to `$null` as settle rows set them, `Head` `$null`, `Outcome` `'budget'`, plus `Max`. Consumers such as `board.ps1:433` read those properties directly under StrictMode 3.0. `Get-PwRoundRows` already leaves them out, so the estimates and progress don't change.
- `board.ps1 rounds` prints a budget row as `budget <round> max=<n> by <login>`.

## Out of scope

- Calling the script from the skills, and the Needs human text (PKT-6).
- A ceiling column in `progress.ps1` (a later follow-up).
- Counting resume sessions, CI-fix runs and the test-failure reruns before a PR, which leave no marker: about 40 credits a packet.

## Owns

- `skills/packet-dispatch/scripts/credit-check.ps1`
- `skills/packet-board/scripts/providers/github-common.ps1`
- `skills/packet-board/scripts/board.ps1`
- `tests/cases/credit-check.tests.ps1`
- `docs/decisions/solo-budget/PKT-5.md`

## Shared touchpoints

- none

## Consumes

- `Get-PwCreditCeiling` (PKT-1).
- From the base: `Get-PwCreditEstimate`, `Get-PwConfig -Ref` and `Get-PwPackets -Ref` (`PacketWorkflow.ps1`), and `Get-PwGhRounds` (`github-common.ps1`).

## Provides

- `credit-check.ps1`, with the interface and exit codes above.
- The marker `` `packet:budget max=<credits>` ``: a PR comment, counted from trusted authors only.
- `budget` rows in `Get-PwGhRounds` and in `board rounds`.

## Acceptance criteria

- [ ] With the ceiling unset, it prints OFF and exits 0, and makes no `gh` call (the test's stub fails if called), even when the packet has no file at the base.
- [ ] An S packet whose round 1 was tier 2, 3 lenses, 1 run, fix, with a ceiling of 1200: `-Next round` for round 2 (tier 2, 2 lenses, 1 run) prints WITHIN. Its so-far, step and total equal `Get-PwCreditEstimate`'s for the same rows. The test sets its own `creditsPerRun` (0.1.1's values) rather than the defaults, so PKT-7's rate change doesn't move it: a ceiling of 900, between so-far (620) and total (about 1,014) on those rates, prints OVER and exits 3. A total equal to the ceiling is WITHIN.
- [ ] A per-size ceiling uses the packet's size as the base has it.
- [ ] A trusted `packet:budget max=2000` turns that OVER into WITHIN, and the output names who raised it. The same comment from an untrusted login changes nothing, nor does one from a login that the base's `trustedAuthors` lists but the default branch's no longer does, and so does a `max` below the configured ceiling. A trusted `max=lots` exits 2.
- [ ] It exits 2, never WITHIN, for each of these: a `creditsPerRun` typo, a broken ceiling, a failed `gh` call, no packet file at the base, and a `-Round` that isn't one more than the last marker. A parameter-binding error (a missing `-Packet`, `-Round abc`) exits non-zero and never 0 or 3. `-Next fix` after a passed round prices the CI fix, and after a fix round at tier 2 with no cap prices the next round at tier 3.
- [ ] The base decides: a ceiling of 500 at the base and 99999 in the branch's config gives OVER.
- [ ] `Get-PwCreditEstimate` and `Get-PwCreditSummary` give the same totals with budget rows among the markers as without them, and `board rounds` lists the budget row, in text and in `-Json`, without error.

## Tests to run

- `pwsh -NoProfile -File tests/run-tests.ps1`

## Decision record

`docs/decisions/solo-budget/PKT-5.md`

## Dispatcher notes

Reuse the stubs the existing "trusted round reader" tests use (`Invoke-PwGh`, `Invoke-PwGhPages`). The raise lives on the PR, like a settle, so the script reads only GitHub, never the board provider. Like a settle, it can be posted by any trusted identity, the dispatcher's own included. PKT-6 forbids that in the instructions, and PKT-8 lists it under Known limitations. The script must not post anything.
