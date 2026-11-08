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

  - **What it reads.** Two configs and two copies of the packet file: at the merge base of `-Base` and `-Head`, as review-scope does, and as merged on origin's default branch (`Get-PwSharedConfig`). A base without a config, a clone without an origin, and an origin whose default branch has no config each exit 2, rather than fall back to the working tree. Markers and raises are read with the trusted authors of the default branch's config, as `board rounds` reads settles.
  - **The ceiling** is the stricter of the two configs' `budget.maxCreditsPerPacket`, each through `Get-PwCreditCeiling` for the packet's size on that side (owner's decision on #35). A ceiling that is set but broken on either side is an error.
  - **The price** is the higher of two estimates: one with the base's config and packet file (rates, `review.tierCap`, `review.lensesPerReviewer`, size, Review tier line), one with the default branch's (owner's decision on #35). So neither the branch nor an old base can lower the ceiling or the price. If the packet file is gone from the default branch, the base's stands in for it.
  - **Ceiling unset.** It reads `budget.maxCreditsPerPacket` from the config itself, with `Get-PwCreditCeiling`'s rule for unset: a `budget` that isn't a table, no `maxCreditsPerPacket` key, or `null`. It prints `OFF` and exits 0 only when neither config sets a ceiling, after reading only those two configs, from git: no packet file, PR, board or `creditsPerRun`. Only a set ceiling goes through `Get-PwCreditCeiling`. An install that sets no ceiling then meets no failure that review-scope's and board's own config reads wouldn't already hit, except that it needs an origin whose default branch has a config.
  - **So far.** `Get-PwCreditEstimate` over the PR's trusted round markers (`Get-PwGhRounds`).
  - **`-Next round`** prices the round review-scope chose: its tier, its lenses and its runs. `-Round` must be one more than the last round marker.
  - **`-Next fix`** adds nothing for the fix itself, since the last round's `outcome=fix` already prices `implementerFix`. It adds the cheapest round that must follow the fix: the last round's confirmed lenses, at its tier plus one (review-scope raises a round after fixed findings), at the later-round factor, in `review.lensesPerReviewer` lenses per run. As review-scope carries a later round (PKT-3), the +1 stops at `review.tierCap` or 3, and the tier never drops below the last round's. After a round that passed (§9.3's CI fix), or one whose outcome is `needs-human` (a fix the owner asked for; owner's decision on #35), it prices `implementerFix`, which no marker will book, plus a one-lens round at that round's tier. After any other outcome it exits 2.
  - **`-Next start`** runs before a claim, with no PR. It prices the base plus a one-lens round at tier 1, or at the packet's **Review tier** line, which review-scope raises round 1 to, so a ceiling no packet of that size can meet stops the packet before anything runs.
  - **A raise.** The newest trusted PR comment `` `packet:budget max=<credits>` `` raises the ceiling for the rest of this packet (owner's decision, question 5). The marker must open the comment. The newest raise wins, even below an older one (owner's decision on #35); a raise at or below the ceiling in force changes nothing. A trusted raise whose `max` isn't a whole number above 0 is an error.
  - **Output.** `WITHIN so-far=<n> step=<n> total=<n> ceiling=<n> (config | config on origin/<branch> | raised by <login> <date>)` exits 0, where `config on origin/<branch>` names the default branch's ceiling when it is the stricter. `-Json` also names the pricing that held and both totals and ceilings. Warnings go to stderr. `OVER` with the same fields exits 3. Any error (config, packet, markers, `gh`, estimator) exits 2 with a message, never WITHIN. The field is `step=`, as in the Needs human marker, where `next=` names the step (`round` or `fix`).
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
- From the base: `Get-PwCreditEstimate`, `Get-PwConfig -Ref`, `Get-PwPackets -Ref`, `Get-PwSharedConfig` and `Get-PwDefaultRemoteRef` (`PacketWorkflow.ps1`), and `Get-PwGhRounds` (`github-common.ps1`).

## Provides

- `credit-check.ps1`, with the interface and exit codes above.
- The marker `` `packet:budget max=<credits>` ``: a PR comment, counted from trusted authors only.
- `budget` rows in `Get-PwGhRounds` and in `board rounds`.

## Acceptance criteria

- [ ] With the ceiling unset in both configs, it prints OFF and exits 0, and makes no `gh` call (the test's stub fails if called), even when the packet has no file at the base. A ceiling set only on the default branch is not OFF.
- [ ] An S packet whose round 1 was tier 2, 3 lenses, 1 run, fix, with a ceiling of 1200: `-Next round` for round 2 (tier 2, 2 lenses, 1 run) prints WITHIN. Its so-far, step and total equal `Get-PwCreditEstimate`'s for the same rows. The test sets its own `creditsPerRun` (0.1.1's values) rather than the defaults, so PKT-7's rate change doesn't move it: a ceiling of 900, between so-far (620) and total (about 1,014) on those rates, prints OVER and exits 3. A total equal to the ceiling is WITHIN.
- [ ] A per-size ceiling uses the packet's size as the base has it.
- [ ] A trusted `packet:budget max=2000` turns that OVER into WITHIN, and the output names who raised it. The same comment from an untrusted login changes nothing, nor does one from a login that the base's `trustedAuthors` lists but the default branch's no longer does, and so does a `max` below the configured ceiling. A trusted `max=lots` exits 2.
- [ ] It exits 2, never WITHIN, for each of these: a `creditsPerRun` typo, a broken ceiling, a failed `gh` call, no packet file at the base, and a `-Round` that isn't one more than the last marker. A parameter-binding error (a missing `-Packet`, `-Round abc`) exits non-zero and never 0 or 3. `-Next fix` after a passed round, or after a Needs human, prices the CI fix, and after a fix round at tier 2 with no cap prices the next round at tier 3. Under `review.tierCap` 2, a round after a tier-3 round is priced at tier 3.
- [ ] The base and the default branch decide, never the branch: a ceiling of 500 at the base and 99999 in the branch's config gives OVER. A base of 1200 with 900 on the default branch gives 900. When the default branch's rates, size or tier cap give a higher total than the base's, that total holds. No origin, or no config on its default branch, exits 2.
- [ ] `Get-PwCreditEstimate` and `Get-PwCreditSummary` give the same totals with budget rows among the markers as without them, and `board rounds` lists the budget row, in text and in `-Json`, without error.

## Tests to run

- `pwsh -NoProfile -File tests/run-tests.ps1`

## Decision record

`docs/decisions/solo-budget/PKT-5.md`

## Dispatcher notes

Reuse the stubs the existing "trusted round reader" tests use (`Invoke-PwGh`, `Invoke-PwGhPages`). The raise lives on the PR, like a settle, so the script reads only GitHub, never the board provider. Like a settle, it can be posted by any trusted identity, the dispatcher's own included. PKT-6 forbids that in the instructions, and PKT-8 lists it under Known limitations. The script must not post anything.
