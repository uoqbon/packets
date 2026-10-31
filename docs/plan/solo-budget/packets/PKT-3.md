# PKT-3 · Cap the review tier except where the top tier is forced

- **Packet:** PKT-3 · **Priority:** P0 · **Size:** M · **Wave:** W1 · **Workstream:** 2 Solo profile · **Target:** 2026-11-09
- **Depends on:** PKT-1
- **Review lenses:** security, architecture, correctness, tests
- **Review tier:** 3
- **Locks:** none
- **Initial status:** Ready

## Goal

With `review.tierCap` 2 (the solo profile), review-scope stops its measured raises at tier 2, so most rounds run on the standard reviewer. These still raise the round to tier 3, the top: review machinery, a `.gitattributes` change, a diff of only lock or generated files, `review.deepPaths`, `review.maxPaths`, and the packet's **Review tier** line. Later rounds never drop below the previous round's tier. With the key unset, nothing changes. The cap is read from the config at the base, so a packet branch can't set it.

## Spec

- Workstream 2 of the source request.
- The tier rules in `skills/packet-review/scripts/review-scope.ps1`'s header.
- `skills/packet-review/SKILL.md` §1 ("The tier is a **floor**").
- docs/cost.md's tier-floor levers, which the cap is a stronger form of.

## In scope

- `review-scope.ps1`, with `tierCap` from the config at the base as every setting is:
  - **Uncapped.** Measure the tier exactly as today; `Uncapped` is that tier.
  - **The cap.** With a cap, the measured tier becomes `min(cap, measured)`.
  - **The floor.** `Floor` is the capped measured tier, so `Tier` is never below `Floor`; `Uncapped` alone carries the measured tier before the cap. The reviewer prompt's tier line then reads, for example, `tier 2 standard (floor 2, capped from 3)`.
  - **Forced reasons.** These make it 3 whatever the cap: `machinery`, `attributes`, `max`, `deep`, and only ignored files changed.
  - **The packet's line.** The packet's **Review tier** line still raises past the cap.
  - **Later rounds.** A round is never below `-PreviousTier`. The +1 for `-FixedConfirmed` stops at the cap unless a forced reason holds.
- **Output:**
  - `Uncapped` and `Settings.TierCap`.
  - Each capped raise stays in `Reasons` as `capped at 2 by review.tierCap: <reason>`.
  - The text output's first line adds `UNCAPPED=<n> (review.tierCap <cap>)` when `Uncapped` differs from `Floor`, which happens only under a cap.
- `ModelCheck`:
  - It holds the round's agent, that agent's class, and packet-dispatcher's class, from `Get-PwAgentModelClass` over the base config's `models`.
  - Its `Warning` is set when the agent's class ranks above the dispatcher's and the two classes list different models. It is `$null` for an agent the kit doesn't ship.
  - It is advisory: if `Get-PwAgentModelClass` throws (a bad `models.agents` entry at the base), ModelCheck puts the message in `Warning`, and review-scope never exits 2 for it.
- `skills/packet-review/SKILL.md`:
  - §1's floor paragraph and Limits item 5 describe the cap and its exceptions.
  - The reviewer prompt's tier line shows `capped from <n>`.
  - When `ModelCheck.Warning` is set, the panel tells the owner before the first pair. The stop itself is PKT-6.
- `round-report-template.md`: the Tier field adds `(capped from <uncapped> by review.tierCap)` when it applies.
- `skills/packet-plan/SKILL.md`:
  - Under a tier cap, a packet that changes auth, a migration or schema, a contract later packets consume, or concurrency gets a `**Review tier:** 3` line, and its Dispatcher notes say why.
  - The size rule says "at most `review.maxRounds` rounds" instead of three.

## Out of scope

- The solo template (PKT-4).
- The credit check (PKT-5, PKT-6).
- Stopping on a reviewer the host refuses (PKT-6).
- The README's safety table (PKT-8).

## Owns

- `skills/packet-review/scripts/review-scope.ps1`
- `skills/packet-review/SKILL.md`
- `skills/packet-review/round-report-template.md`
- `skills/packet-plan/SKILL.md`
- `tests/cases/tier-cap.tests.ps1`
- `docs/decisions/solo-budget/PKT-3.md`

## Shared touchpoints

- none

## Consumes

- `review.tierCap` from `Get-PwConfig`, and `Get-PwAgentModelClass` (PKT-1).

## Provides

- review-scope JSON: `Uncapped` (int), `Settings.TierCap` (int or null), and `ModelCheck` (`Agent`, `AgentClass`, `DispatcherClass`, `Warning`).

## Acceptance criteria

- [ ] With `tierCap` unset, `null` or 3, review-scope's `Tier`, `Floor`, `Agent`, `Reasons`, `Lenses`, `Runs`, `Pairs` and existing `Settings` match the base's for every diff in the existing suite. The only new fields are `Uncapped` (equal to `Floor`), `Settings.TierCap` and `ModelCheck`.
- [ ] With `tierCap` 2, a 412-line code diff in one subsystem is tier 2 with `Floor` 2 and `Uncapped` 3. The suite's auth-path-and-semaphore diff (PKT-03 in the sample) is tier 2 too, and its reasons say capped.
- [ ] With `tierCap` 2, each of these is tier 3:
  - a `review.deepPaths` match, or a `review.maxPaths` match;
  - a change under `.github/skills`, `.github/agents`, `.github/hooks`, `.github/workflows` or the project lens folder;
  - a change to `.github/packet-workflow.json` or `.gitattributes`;
  - a lockfile-only diff;
  - a packet whose **Review tier** line is 3.
- [ ] With `tierCap` 2, `-PreviousTier 2 -FixedConfirmed` stays 2, and `-PreviousTier 3` with no forced reason left stays 3.
- [ ] `Settings.TierCap` reports the base's value. A branch that sets `tierCap` 2 over a base without one gets no cap (and tier 3, since the config change is machinery).
- [ ] `ModelCheck.Warning` names `packet-reviewer-deep`, both classes and the Local harness on a tier-3 round when `models.strong` and `models.standard` differ and `models.agents` puts the dispatcher on standard. It is null with the template's identical lists. With a `models.agents` entry naming an unknown class, review-scope still exits 0 and `Warning` holds the error.
- [ ] A `tierCap` the config check refuses (1) makes review-scope exit 2.

## Tests to run

- `pwsh -NoProfile -File tests/run-tests.ps1`

## Decision record

`docs/decisions/solo-budget/PKT-3.md`

## Dispatcher notes

This packet weakens what the panel sees, by design. The decision record must list each raise the cap stops (more than 300 lines, more than 8 files, two subsystems, migration, contract, auth, infrastructure, concurrency, the +1 after fixes), and each one it doesn't. The PR says, in a sentence, what this does to the safety model (CONTRIBUTING.md). The forced list is the owner's decision (question 3): machinery, `deepPaths`, `maxPaths`, `.gitattributes`, a diff of only ignored files, and the Review tier line. Auth and migration raises stay capped; deep review for those comes from Review tier lines and `deepPaths`. With GPT-6.1 Sol in every class, tiers 2 and 3 run the same model; what the cap takes away is tier 3's reasoning effort (high instead of medium, where the harness honours it), its adversarial cross-file remit and its extra calls.
