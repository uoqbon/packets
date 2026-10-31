# PKT-1 · Add the new config keys and a test-case folder

- **Packet:** PKT-1 · **Priority:** P0 · **Size:** M · **Wave:** W0 · **Workstream:** Foundation · **Target:** 2026-11-04
- **Depends on:** none
- **Review lenses:** architecture, correctness, tests
- **Locks:** none
- **Initial status:** Ready

## Goal

Land the contracts every later packet codes against: three new config keys whose defaults change nothing, the functions that read them, the kit's lens list, and a folder where each packet adds its own offline tests. With these in place, the W1 and W2 packets run in parallel without editing `PacketWorkflow.ps1`, the default template or `tests/run-tests.ps1`.

## Spec

- Workstreams 2 and 3 of the source request: the cap, the per-agent model class and the ceiling.
- [docs/cost.md](../../../cost.md), lean change #8 (`"models": { "agents": { … } }`).
- `Get-PwConfig` and the `budget` comment in `skills/packet-board/scripts/PacketWorkflow.ps1` ("budget is checked where it is used").

## In scope

- `review.tierCap` in `$script:Defaults.review` (`$null`). `Get-PwConfig` accepts `null` (no cap) or the whole number 2 or 3, where a quoted `"2"` counts as for the other review limits. It stops on anything else with `config: review.tierCap must be 2 or 3, or null for no cap (got '<value>')`.
- `budget.maxCreditsPerPacket` in `$script:Defaults.budget` (`$null`). `Get-PwConfig` doesn't check it, so a typo can't stop the board. `Get-PwCreditCeiling -Config <cfg> -Size <S|M|L>` returns `$null` when it is unset, and a number when it is set. That is either one positive number for every size, or a table `{ "S": n, "M": n, "L": n }`. Anything else stops it: zero, a negative number, a string, a bool, or a table without the size.
- `models` in `$script:Defaults`: the template's three class lists and `agents = @{}`. `$script:AgentModelClass`: the five kit agents and their classes, as `install.ps1` maps them today. `Get-PwAgentModelClass -Models <map> -Agent <name>` returns the class from `models.agents`, else the kit's. It returns `$null` for an agent the kit doesn't ship, such as a project's own reviewer in `review.agents`. It stops when `models.agents` names an agent that isn't one of the five, or a class that isn't `strong`, `standard` or `light`.
- `$script:KitLenses`: the eleven lens names.
- `templates/packet-workflow.json`: `"tierCap": null` under `review`, `"maxCreditsPerPacket": null` under `budget`, `"agents": {}` under `models`.
- `tests/run-tests.ps1`: after the existing suite and before `Remove-Item $cultureRun` (so `Invoke-KitIn` still works), run each `tests/cases/*.tests.ps1` in ordinal file-name order, each in a child scope of its own (`& { . $file }`). No case file's plain variables then reach the suite or the next case file, and `Assert-That`'s `$script:` counters still count. A child scope doesn't isolate `$script:` variables, so case files keep their state in plain variables and never assign a `$script:` one. A case file that throws counts as one failure named after the file. Case files may use `Assert-That`, `Invoke-Kit`, `$kit`, `$skills` and two new helpers.
  - `New-CaseRepo` makes a throwaway repository with the sample phase. Its `origin` is a local bare repository, pushed to, with `git remote set-head origin main`, as `run-tests.ps1:381` does, so `board` and `progress.ps1` find origin's default branch. Its config is the template's with the `local` board, and the helper writes `repo` into it itself. A case file that runs `install.ps1` into a case repository writes `repo` itself too: the installer fills it only from a github.com origin.
  - `Remove-CaseRepo` removes the repository, unless `-Keep`.
- `tests/cases/config-keys.tests.ps1` for all of the above.

## Out of scope

- Using `tierCap` in review-scope (PKT-3).
- The credit check (PKT-5) and its wiring (PKT-6).
- Per-agent classes in the installer, and the solo template (PKT-4).
- Moving existing tests into `tests/cases/`: only new tests go there.

## Owns

- `skills/packet-board/scripts/PacketWorkflow.ps1`
- `templates/packet-workflow.json`
- `tests/run-tests.ps1`
- `tests/cases/config-keys.tests.ps1`
- `docs/decisions/solo-budget/PKT-1.md`

## Shared touchpoints

- none

## Consumes

- The kit at the base: `Get-PwConfig`, `Merge-PwHashtable`, `Stop-Pw`, `Get-PwCreditRate` (`skills/packet-board/scripts/PacketWorkflow.ps1`), and the test helpers at the top of `tests/run-tests.ps1`.

## Provides

- `Get-PwConfig` fills `review.tierCap`: `$null`, 2 or 3, as `[int]` or `$null`.
- `Get-PwCreditCeiling -Config <cfg> -Size <S|M|L>`: `[double]` or `$null`; throws `PwError` on a bad value.
- `Get-PwAgentModelClass -Models <IDictionary> -Agent <string>`: `'strong'`, `'standard'`, `'light'` or `$null`; throws `PwError` on a bad `models.agents` entry.
- `$script:AgentModelClass` (agent name → class) and `$script:KitLenses` (string array).
- `New-CaseRepo` and `Remove-CaseRepo` in `tests/run-tests.ps1`; case files are `tests/cases/<name>.tests.ps1`.

## Acceptance criteria

- [ ] Every test that passes on the base (243 at 0.1.1) still passes unchanged, and review-scope's JSON for the existing sample diffs is byte-identical to the base's.
- [ ] `tierCap` of `null`, 2, 3 and `"2"` loads; 0, 1, 4, 2.5, `"two"` and `true` each make review-scope exit 2 with a message naming `review.tierCap`.
- [ ] `Get-PwCreditCeiling`: unset gives `$null`; 1500 gives 1500 for S, M and L; `{ "S": 900, "M": 1300, "L": 2000 }` gives 1300 for M; `{ "S": 900 }` for M, 0, -5, `"lots"` and `true` each throw with a message naming `budget.maxCreditsPerPacket`. A config with a broken ceiling still loads for `board show` and `progress.ps1`.
- [ ] `Get-PwAgentModelClass` gives the five agents the classes `install.ps1` writes today; with `{ "packet-dispatcher": "standard" }` only the dispatcher changes; an agent the kit doesn't ship gives `$null`; a `models.agents` key `packet-reviewer-max` or a class `premium` throws.
- [ ] `$script:KitLenses` equals the base names of `skills/packet-review/lenses/*.md`.
- [ ] A case file's asserts count in the summary; one that throws adds a failure and the run exits 1; a variable one case file sets is not seen by the next; no file in `tests/cases/` assigns a `$script:` variable (a test greps for it); with no case files the run prints what it printed before.
- [ ] In a `New-CaseRepo` repository, `board show` and `progress.ps1 -Json` exit 0.

## Tests to run

- `pwsh -NoProfile -File tests/run-tests.ps1`

## Decision record

`docs/decisions/solo-budget/PKT-1.md`

## Dispatcher notes

Contracts first: keep it small and land it fast, since W1 waits on it. Don't change any credit rate here: PKT-7 does that. `Get-PwConfig`'s comment says budget is checked where it is used; keep that true for the ceiling. The defaults table is copied before `Get-PwConfig` fills it in (a test pins that), so add `models` and the new keys without breaking the "defaults untouched" test. Case files run in child scopes, so they can't overwrite the suite's variables; `New-CaseRepo` must still leave the current directory as it found it.
