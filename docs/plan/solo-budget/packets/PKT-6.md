# PKT-6 · Stop at the credit ceiling or a refused reviewer

- **Packet:** PKT-6 · **Priority:** P0 · **Size:** M · **Wave:** W2 · **Workstream:** 3 Credit ceiling · **Target:** 2026-11-12
- **Depends on:** PKT-3, PKT-5
- **Review lenses:** security, architecture, correctness, tests
- **Review tier:** 3
- **Locks:** none
- **Initial status:** Ready

## Goal

The dispatcher and the panel run `credit-check.ps1` before every review round and every fix run. They treat a reviewer the host won't start as a stop, never as a reason to use a lighter model or agent. Either way the packet goes to Needs human with a trusted marker that `resume` reads. At a budget stop the owner can raise the ceiling for this packet or stop it. When the stop came before a fix, so the PR head is the one the panel reviewed, they can also pass the round's findings as follow-ups through a settle. A model-tier stop offers no settle: those are the forced tier-3 rounds, where the deep reviewer matters most. A check that fails (exit 2) never lets the packet go on.

## Spec

- Workstreams 2 and 3 of the source request.
- `skills/packet-dispatch/SKILL.md`: §1 Select, §8 Review rounds, §9 Hand off, Needs human, Resume, Settle, Never, and Preflight step 7 (Models).
- `skills/packet-review/SKILL.md` §1 and §2.
- VS Code's subagent docs, Local harness: a subagent whose model exceeds the session's cost tier "doesn't run and reports which models are available".

## In scope

- **`skills/packet-dispatch/SKILL.md`:**
  - **§1 Select.** `credit-check -Next start` runs before the claim. On OVER, don't start the packet, and tell the owner. Nothing is claimed, so there is no Needs human.
  - **§8 Fix.** Before the implementer, `credit-check -Next fix`. Exit 0: go on. Exit 1: Needs human (budget). Exit 2: stop and report, and release the claim. §9.3's CI fix goes through §8 Fix, and §9.2's conflict round and Amend's round go through the panel's check, so each is covered. Say so in the text.
  - **The last round, not three.** §9.3's "If three rounds are used" and Needs human's "after round 3" become the last round (`review.maxRounds`).
  - **Needs human,** two new kinds, each with an exact first line and its own options:
    - `` `packet:needs-human reason=budget next=<round|fix> round=<N> so-far=<n> step=<n> ceiling=<n> head=<sha>` ``. Options:
      1. raise: comment `` `packet:budget max=<credits>` `` on the PR, then resume;
      2. pass with follow-ups: a settle at this head (**Settle**), offered only when `next=fix`, so the head is the one the newest round reviewed; the comment names any blocking findings it would pass;
      3. stop: close the PR and move the item to Backlog.
    - `` `packet:needs-human reason=model-tier agent=<agent> round=<N> head=<sha>` ``, with the host's message quoted. Options:
      1. resume from a dispatcher session on a model at least as dear as the agent's;
      2. resume in the Copilot harness;
      3. give the agent the dispatcher's class in `models.agents` (weakens what its tier means), merge that, and reinstall;
      4. stop: close the PR and move the item to Backlog.

      No settle: the head isn't one a panel reviewed.
  - **Resume §4.**
    - `reason=budget`, three ways on:
      - a trusted `packet:budget` on the PR, newer than the stop: set In review and carry on at `next=`, where the check runs again;
      - a settle request newer than the stop, at the newest round's head and describing no change: **Settle**, to pass with follow-ups;
      - the PR closed: release, and stop.

      Anything else: release and stop.
    - `reason=model-tier`: retry the round. If the host refuses again, the same Needs human. A settle request isn't an answer here: say so on the item, and keep it Needs human.
  - **Settle (the narrow widening, owner's decision, question 7).** When the rounds are used up, a settle works as today. Before the last round it counts only when all of these hold:
    - the item's last Needs human is `reason=budget next=fix`;
    - the request's `head` is the newest round's head, and the PR's head now;
    - it describes no change.

    It then passes that round's confirmed findings as follow-ups: one issue each, under packet-review §5's rules, contract questions included, opened before the settle-check. It never carries a code change, so nothing a panel hasn't reviewed reaches Ready to merge this way.
  - **Never:** post a `packet:budget` or `packet:settle` comment, or raise or change the ceiling. (Today's Never list doesn't name settles: only the Settle section says the owner posts them.)
  - **Preflight step 7.** A host that refuses a pinned model for its cost tier is offering it, not withholding it: that is a model-tier stop, not a reason to ask the owner for another model.
- **`skills/packet-review/SKILL.md`:**
  - **§1.** After review-scope, `credit-check -Next round` with this round's `Tier`, `Lenses` and `Runs`. Exit 1: start no pair, set Needs human (budget), and return Needs human. Exit 2: stop the round with no report.
  - **§2.** A reviewer the host won't start stops the round. No other model, no lower tier's agent, no fewer runs, no report: Needs human (model-tier).
  - **Limits:** a sixth limit, the credit ceiling.
- `round-report-template.md`: an optional `**Credits** <so far, with this round> of <ceiling> (estimate)` line.
- `agents/packet-dispatcher.agent.md`: the cost-tier sentence points at the model-tier stop, and the Never list forbids raising the ceiling.
- `tests/cases/stops.tests.ps1`:
  - It pins each rule's text, as the existing guard tests pin theirs.
  - It checks that both first lines parse with `Get-PwMarker`, and that `board marker <ID> needs-human -Json` reads them back on the local board.

## Out of scope

- `credit-check.ps1` itself (PKT-5).
- The e2e stages that exercise these steps in a live harness (PKT-9).
- The README (PKT-8).

## Owns

- `skills/packet-dispatch/SKILL.md`
- `skills/packet-review/SKILL.md`
- `skills/packet-review/round-report-template.md`
- `agents/packet-dispatcher.agent.md`
- `tests/cases/stops.tests.ps1`
- `docs/decisions/solo-budget/PKT-6.md`

## Shared touchpoints

- none

## Consumes

- `credit-check.ps1` and its exit codes, and the `packet:budget` marker (PKT-5).
- review-scope's `Settings.TierCap` and `ModelCheck` (PKT-3).

## Provides

- The `reason=budget` and `reason=model-tier` Needs human markers, and how `resume` reads them.

## Acceptance criteria

- [ ] packet-review §1 runs `credit-check -Next round` after review-scope and before §2. packet-dispatch §8 Fix runs `-Next fix` before the implementer, and §1 Select runs `-Next start` before the claim. Each says what exit 0, 1 and 2 do, and exit 2 never goes on.
- [ ] Needs human gives both first lines exactly. Each parses with `Get-PwMarker` as kind `needs-human` with its pairs, and `board marker <ID> needs-human -Json` on the local board returns them.
- [ ] Resume handles `reason=budget` (a raise, a settle, a closed PR, no answer) and `reason=model-tier` (a retry; a settle request refused), and each path ends in another check or a release.
- [ ] Before the last round, a settle counts only after `reason=budget next=fix`, at the newest round's head, with no change described; it opens the follow-ups before the settle-check. The text pins each condition.
- [ ] No text in the dispatch or review skill, or in the dispatcher agent, says "three rounds" or "round 3" where `review.maxRounds` applies.
- [ ] The Never lists of the dispatch skill and the dispatcher agent forbid posting `packet:budget` and `packet:settle`.
- [ ] Every existing guard and dispatch-text test passes unchanged.

## Tests to run

- `pwsh -NoProfile -File tests/run-tests.ps1`

## Decision record

`docs/decisions/solo-budget/PKT-6.md`

## Dispatcher notes

This packet changes instructions only, plus the tests that pin them. Keep `## Only a person starts a dispatch` and `## Only a person starts you` byte-identical: the existing tests and the e2e prompt pin them. The narrow settle adds no way for code a panel never saw to reach Ready to merge: before the last round it can only pass reported findings, at the reviewed head. Say that in the PR's safety-model sentence.
