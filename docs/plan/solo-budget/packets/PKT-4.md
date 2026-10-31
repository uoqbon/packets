# PKT-4 · Add the solo profile and a model class per agent

- **Packet:** PKT-4 · **Priority:** P0 · **Size:** M · **Wave:** W2 · **Workstream:** 2 Solo profile · **Target:** 2026-11-12
- **Depends on:** PKT-1, PKT-2, PKT-7
- **Review lenses:** ops, correctness, tests
- **Locks:** none
- **Initial status:** Ready

## Goal

`install.ps1 -Profile solo` starts a repository on the default template with `templates/packet-workflow.solo.json` merged onto it: an overlay of only the solo profile's keys. `models.agents` puts any kit agent on any model class, so the dispatcher can run on the standard class (cost.md lean change #8). The installer warns when that setup could stop a review round in the Local harness.

## Spec

- Workstream 2 of the source request.
- docs/cost.md: the Recommended budget profile, and lean change #8.
- `install.ps1`'s `$agentModelClass` map and its `model:` rewrite.
- VS Code's subagent docs, Local harness: "Explicit and agent-configured model selections are checked against the main model's cost tier. If a selection exceeds that tier, the subagent doesn't run and reports which models are available."

## In scope

- `templates/packet-workflow.solo.json`: an overlay that holds only these keys. The installer merges it onto the default template with `Merge-PwHashtable`, so everything else (board, labels, `lensPaths`, model lists, `creditsPerRun`) comes from the default template and can't drift:

  | Key | Value |
  | --- | --- |
  | `review.maxRounds` | 2 |
  | `review.lensesPerReviewer` | 3 |
  | `review.shouldFixPassFromRound` | 2 |
  | `review.tierCap` | 2 |
  | `models.agents` | `{ "packet-dispatcher": "standard" }` |
  | `budget.maxCreditsPerPacket` | `{ "S": 1000, "M": 1500, "L": 2200 }`: about 1.5× a typical solo packet, so only a packet forced to tier 3 with many lenses trips it (owner's decision, question 4) |

  It holds no model lists and no `creditsPerRun`: those are the default template's, which PKT-7 puts on GPT-6.1 Sol rates. Every class lists the same models, so the dispatcher's class doesn't change its rate.
- `install.ps1 -Profile default|solo` (default `default`). It chooses the template for a new config only. On an existing config it writes nothing to the config, and lists each of the overlay's keys whose value differs in the config, so the owner can move them over in a PR.
- **Per-agent classes.** Each agent's `model:` line comes from `Get-PwAgentModelClass` over the config's `models`: `models.agents` first, else the kit's map. The installer dot-sources the kit's own `PacketWorkflow.ps1` for it. A `models.agents` entry that names an unknown agent or class stops the install before any file is written.
- **Static model-tier warning.** The installer warns when packet-dispatcher's class ranks below one of its subagents' classes and the two classes list different models. The warning says:
  - in the Local harness, a subagent on a model in a higher cost tier than the session's doesn't run;
  - the round then stops at Needs human (PKT-6);
  - the fix is to run those dispatches in a session on the higher model, or to give that agent the dispatcher's class.
- The "Agent models:" summary names each agent whose class differs from the kit's.
- `-PlanOnly -Profile solo` writes the plan-only files and the solo config.

## Out of scope

- The cap (PKT-3), and the ceiling (PKT-5, PKT-6).
- The dispatcher agent's text (PKT-6).
- The docs (PKT-8).
- Changing an existing config.

## Owns

- `install.ps1`
- `templates/packet-workflow.solo.json`
- `tests/cases/solo-install.tests.ps1`
- `docs/decisions/solo-budget/PKT-4.md`

## Shared touchpoints

- none

## Consumes

- `Get-PwAgentModelClass`, `$script:AgentModelClass`, `review.tierCap` and `budget.maxCreditsPerPacket` (PKT-1).
- `install.ps1 -PlanOnly` and the manifest's `mode` (PKT-2).
- The default template's `budget.creditsPerRun` on GPT-6.1 Sol rates (PKT-7), which the overlay inherits and its ceiling values assume.

## Provides

- `install.ps1 -Profile <default|solo>`.
- `templates/packet-workflow.solo.json`, the solo overlay.

## Acceptance criteria

- [ ] `templates/packet-workflow.solo.json` holds only the overlay's keys. `-Profile solo` on a fresh repository writes the default template merged with it, with `repo` and the default branch filled in, and `Get-PwConfig` on it gives `maxRounds` 2, `lensesPerReviewer` 3, `shouldFixPassFromRound` 2 and `tierCap` 2.
- [ ] There, the installed dispatcher's `model:` line is the standard list and the deep reviewer's is the strong list. With the default profile and no `models.agents`, every installed agent equals its source, as today.
- [ ] `-Profile solo` on an existing config leaves it byte-identical and lists only the overlay's keys that differ (for example `review.maxRounds: 3 → 2`), never `repo`, the board or another key the overlay doesn't hold.
- [ ] A `models.agents` entry naming `packet-reviewer-max`, or a class `premium`, makes the install exit non-zero before it writes; the target's files and manifest are unchanged.
- [ ] With different strong and standard lists and the dispatcher on standard, the output warns and names `packet-reviewer-deep` and the Local harness. With identical lists (both templates as shipped) it doesn't warn.
- [ ] `-PlanOnly -Profile solo` installs the plan-only files with the solo config.
- [ ] Every existing installer test passes unchanged.

## Tests to run

- `pwsh -NoProfile -File tests/run-tests.ps1`

## Decision record

`docs/decisions/solo-budget/PKT-4.md`

## Dispatcher notes

`install.ps1` must not call `Get-PwConfig`: a new config can fail its `repo` check before the installer fills it in. Dot-source `PacketWorkflow.ps1` for the class map and helpers only. With the shipped model lists (GPT-6.1 Sol first in every class), putting the dispatcher on standard costs nothing and saves nothing. It pays off once `models.strong` names a dearer model, and the decision record says so. The solo overlay carries no `creditsPerRun`: it inherits the default template's, as PKT-7 leaves them, and H-2 replaces only those.
