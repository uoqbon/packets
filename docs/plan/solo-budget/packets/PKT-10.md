# PKT-10 · Make every installer error exit 2

- **Packet:** PKT-10 · **Priority:** P2 · **Size:** S · **Wave:** W3 · **Workstream:** 2 Solo profile · **Target:** 2026-11-17
- **Depends on:** PKT-4
- **Review lenses:** ops, tests
- **Locks:** none
- **Initial status:** Backlog

## Goal

`install.ps1` exits 2 on every error, as CONTRIBUTING.md's convention and the README's safety table ("every script exits 2 on an error") say, so a wrapper or CI step that stops on exit 2 stops on any failed install. Since PKT-4 the installer is split: its `models.agents` check exits 2, but its older errors exit 1 through `throw` or `exit 1`, and PowerShell's own parameter errors exit 1 before the script runs. The owner decided on 2026-11-08, in PKT-4's review (uoqbon/packets#39), that a later packet makes them all 2.

## Spec

- CONTRIBUTING.md, Conventions: "The scripts the skills run exit 2 on an error".
- README.md, Safety model: "A failed check never counts as a pass".
- `docs/decisions/solo-budget/PKT-4.md`, decision 8; `docs/decisions/solo-budget/PKT-2.md`, decision 7 (the refusal's exit 1).

## In scope

- **Every error path in `install.ps1` exits 2,** with its message on stderr and nothing on stdout after it. These are the installer's error paths as of PKT-4:
  - the target isn't inside a git repository;
  - `.github/packet-workflow.json` isn't valid JSON;
  - `models.<class>` names no model;
  - the `-PlanOnly` refusal on a full install (today `exit 1`, from PKT-2);
  - a bad `models.agents` entry (already 2; unchanged);
  - any other terminating error while the installer runs, such as a file it can't read or write.
- **Parameter errors exit 2 too:** an unknown `-Profile` value, and a missing or empty `-Target`. Today PowerShell's parameter binding refuses them with exit 1 before any of the script runs, so the script has to check them itself.
- **Messages and order stay as they are:** each error says what it said before (the refusal still lists the files a downgrade would remove), and each still stops before the step it stopped before. A run that stopped without writing still writes nothing.
- **PKT-2's tests re-pinned:** the four assertions in `tests/cases/plan-only.tests.ps1` that expect `Code -eq 1` from the installer (an empty `models.strong` without `-PlanOnly`; the refusal; the refusal under `-DryRun`; a manifest without `mode`) expect 2. Nothing else in that file changes. The owner approved this re-pin with the decision above.
- New tests in `tests/cases/installer-exit-codes.tests.ps1`, one per error path above.

## Out of scope

- Any other script's exit codes: the skills' scripts already exit 2 on an error, and `check-scope.ps1`'s and `board.ps1`'s exit 1 for a failed check (`OUTSIDE`, `LOST`, a held lock) is a verdict, not an error.
- The README, the cost page and other docs (PKT-8 owns the README; it states no installer exit code today).
- `VERSION` and `CHANGELOG.md` (H-3).
- What the installer installs, the profiles and the warning (PKT-2, PKT-4).

## Owns

- `install.ps1`
- `tests/cases/plan-only.tests.ps1`
- `tests/cases/installer-exit-codes.tests.ps1`
- `docs/decisions/solo-budget/PKT-10.md`

## Shared touchpoints

- none

## Consumes

- `install.ps1` as PKT-4 leaves it: `-Profile`, the `models.agents` check (exit 2, stderr, "Nothing was written"), and the `-PlanOnly` refusal from PKT-2.
- `Invoke-Kit` from `tests/run-tests.ps1` (returns the exit code and the merged output).

## Provides

- An installer whose only non-zero exit code is 2.

## Acceptance criteria

- [ ] Each error path in In scope makes `install.ps1` exit 2 and print its message on stderr: run with stdout and stderr captured apart, stderr holds the message and stdout has nothing after the error.
- [ ] An unknown `-Profile` (such as `lean`) and a missing or empty `-Target` exit 2, write nothing, and say which values are allowed or what is missing.
- [ ] The `-PlanOnly` refusal exits 2, still writes nothing, and still lists exactly the files a downgrade would remove.
- [ ] A snapshot of every file under the target's `.github` is unchanged after each failing run that stopped before writing today.
- [ ] A successful install still exits 0, with output unchanged.
- [ ] Every other existing test passes unchanged; in `tests/cases/plan-only.tests.ps1` only the four installer exit-code assertions named in In scope change, from 1 to 2.

## Tests to run

- `pwsh -NoProfile -File tests/run-tests.ps1`

## Decision record

`docs/decisions/solo-budget/PKT-10.md`

## Dispatcher notes

The owner decided this phase isn't dispatched: these are notes for whoever builds it. A top-level `trap` that writes the message to stderr and exits 2 covers `throw` and other terminating errors. It can't cover parameter binding, which fails before the script body runs, so `-Profile` loses its `[ValidateSet]` and `-Target` its `Mandatory` in favour of checks at the top of the script. Without `Mandatory`, a missing `-Target` no longer prompts in an interactive shell; say so in the decision record. Keep `catch [PwError]` for the `models.agents` check, or fold it into the trap, as long as its message stays. The case-file rules from PKT-1 apply: plain variables, kit code only through `Invoke-Kit` or `Invoke-CaseProbe`, nothing dot-sourced. PKT-10 is behind the cut line and isn't on the release's path: if it merges before H-3, the release notes name the change, since a wrapper that checked for exit 1 sees 2.
