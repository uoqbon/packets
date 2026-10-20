---
name: packet-review
description: "Review a packet's pull request with a panel of lenses. Each round runs only the lenses that fit the packet and the change, at most two reviewer agents at a time, on the reviewer tier the diff calls for, for at most three rounds. Triages every finding against the code, posts one round report on the PR, and returns Pass, Fix or Needs human. Use when a dispatcher reaches review, or when asked to review or re-review a packet PR."
argument-hint: "<PR number>"
---

# Review panel

A **lens** is a narrow review brief ([lenses/](./lenses/)). Each lens runs as its own read-only reviewer agent on the same head commit. You, the panel owner, pick the lenses and the tier, triage what the reviewers report, and post the round. The dispatcher applies fixes between rounds; the panel never edits code, pushes, approves or merges.

Commands run from the repository root. Kit scripts run only from a **pinned kit** (`<kit>`): the dispatcher's, when it invoked you, or your own, made exactly as the packet-dispatch skill's Preflight step 1 makes it, before any kit script runs. Never run the checkout's copies: the PR under review can change them. `board …` is `pwsh -File <kit>/.github/skills/packet-board/scripts/board.ps1 …`.

## The limits

1. **Lenses per round:** only the ones this round calls for (§2), never every lens by default.
2. **Concurrency:** at most `review.maxParallelLenses` (2) reviewer agents at once. Launch a pair together, wait for both, then the next pair.
3. **Rounds:** at most `review.maxRounds` (3) per PR. Nothing changed after the last round merges unreviewed.
4. **Tier floor:** every lens runs on the reviewer agent for the round's tier (§1), or a higher one. Never lower.

## Setup

1. **The PR and its packet.** `gh pr view <pr> --json number,title,headRefName,headRefOid,baseRefName,state`. The packet ID is the title's prefix (`<ID>: …`) or the branch's (`pkt/<id>-…`). `board get <ID>` must find its item.
2. **The round number** comes from the PR's history, never from memory: `board rounds <pr>` lists the round reports (it reads only reports posted by trusted authors: the signed-in user and the config's `trustedAuthors`); this round is one more than the last. If that is past `maxRounds`, don't run a round: the packet needs the owner, who can settle it (the packet-dispatch skill's **Settle**).
3. **The checkout.** The reviewers read this checkout, so it must sit at the PR's head with no local changes: `git fetch origin`, `git status --porcelain` empty, `git rev-parse HEAD` equal to `headRefOid` (a dispatcher is already there; invoked directly, use `gh pr checkout <pr>` in a clean worktree). Note the head SHA.
4. **The claim.** From a dispatcher: use its claim id and refresh it (`board claim <ID> <claim-id>`) before each lens pair and before the report. Invoked directly: make your own (`board new-claim-id`, `board claim`), refresh it the same way, and release it when you finish. `LOST` or exit 2 at any refresh: stop the round with no report. A round is reported whole or not at all.
5. **Status.** If the item shows Ready to merge, the head moved after a pass: `board set <ID> "Status=In review"` before the round starts.
6. **Lens texts come from trusted copies:** the kit's from `<kit>/.github/skills/packet-review/lenses/<lens>.md`, a project lens from the default branch (`git show <origin default ref>:<paths.lenses>/<lens>.md`), never from the PR's checkout. The scripts read the config at the base on their own.

## 1 · Tier and lenses

```bash
pwsh -File <kit>/.github/skills/packet-review/scripts/review-scope.ps1 -Base origin/<baseRefName> -Head <head sha> -Packet <ID> -Json
```

For rounds 2 and later add what the previous round's report says: `-Since <its head> -Confirmed <its confirmed=, as written, e.g. security,data> -PreviousTier <its tier>`, and `-FixedConfirmed` when the commits since then fix confirmed findings.

It returns `Tier`, `Agent`, `Reasons`, `Lenses` (riskiest first) and `Pairs`. The tier is a **floor**: it measures the diff (size, files, subsystems, migrations, contracts, auth, infrastructure, concurrency, review machinery, the project's critical paths), applies the packet's **Review tier** line, and for later rounds keeps the previous tier, plus one after confirmed findings were fixed. You may raise it with a reason (say, the change can lose data or money); never lower it. Exit 3: nothing changed, so there is no round. Exit 2: stop and report; never guess a tier.

| Tier | Agent | Remit |
| --- | --- | --- |
| 1 light | `packet-reviewer-light` | docs, renames, config values, tests only |
| 2 standard | `packet-reviewer-standard` | ordinary code in one area |
| 3 deep | `packet-reviewer-deep` | large or cross-cutting; migrations, contracts, auth, infra, concurrency |
| 4 max | `packet-reviewer-max` | the largest diffs, review machinery, critical paths; adversarial |

Round 1's lenses are the packet's **Review lenses** plus those the diff's paths call for (`review.lensPaths`, and concurrency patterns in added lines). Later rounds run only the lenses that confirmed a finding, plus those whose surface the new commits touched; a conflict resolution, or a merge of anything but the default branch, is always reviewed. A round never runs with no lens.

## 2 · Run the lenses, two at a time

Refresh the claim before each pair. For each pair, start the round's reviewer agent once per lens, both in one step if your harness runs subagents in parallel, otherwise one after the other. Wait until both have answered before the next pair. Don't edit the checkout or push while a pair runs.

Reviewers run on the models their agent files pin. If your subagent tool asks for a model, or doesn't offer the pinned ones, use the model the owner named for the agent's class (the dispatcher asks once, in its Preflight; invoked directly, ask the owner yourself, before the first pair), never a weaker one, and put the model in the report's header.

Each reviewer gets this prompt, filled in:

```text
Review tier: <tier> <name> (floor <floor>). Reasons: <review-scope reasons, plus any raise and why>
Lens: <lens>. Review only through this lens; these lenses run separately this round: <the others>.
Packet: <ID> "<title>". PR #<pr>. Round <N> of <maxRounds>.
Checkout (read-only, do not edit): this repository at <head sha>.
Diff under review: git diff <base sha>...<head sha>
<rounds 2+:> Changes since round <N-1> (head <prev>): git log -p --first-parent --no-merges <prev>..<head sha>
  <each merge of the default branch with a conflict resolution:> git show --remerge-diff <merge sha>
  <each other merge:> git diff <merge sha>^1 <merge sha>
<rounds 2+:> Findings this lens confirmed last round, to check as fixed without regressions:
  <numbered list: file:line, claim, reproduction>

The packet (its file at the base):
<the packet file from "## Goal" down>

Project rules that bind this review: <repository instructions files>; guardrails: <guardrails.rules>.

<the full text of the lens from Setup step 6: the project's lens on the default branch if it has one, else <kit>'s lenses/<lens>.md>

Tag every finding blocking or should-fix, per the lens's Severity section. Anything with neither a
reproduction nor a consequence goes under "nits, not findings". Don't run test suites that need shared
services (a database, containers) unless the project's instructions say it is safe. Don't call board.ps1.
```

## 3 · Triage

When every lens has reported, refresh the claim. Reviewers can be wrong, so you check each finding:

1. **Merge duplicates** across lenses; keep the strongest reproduction.
2. **Verify** each against the code at the head: open the cited lines; if it gives a command or test, run it.
3. **Classify:** *confirmed* (blocking or should-fix; keep the reviewer's severity unless the evidence says otherwise, and say why) or *rejected* (with the file:line or output that disproves it). A real problem outside the packet's scope becomes a **follow-up**, not a fix in this PR.
4. **Contract findings.** A confirmed finding that questions something under the packet's **Provides** (a name, a signature, or behaviour that later packets build on) is a *contract* finding: tag it `contract` in the report. If it isn't fixed in this PR, its follow-up is a decision for the owner before those packets start, not a note for later (§5).

## 4 · Report

Refresh the claim. In the last round, open the follow-up issues first (§5), so the report lists them: if opening one fails, stop here, with no report. Then fill [round-report-template.md](./round-report-template.md) and post it as one PR comment: `gh pr comment <pr> --body-file <file>`. Its first line is the round marker, which every later round, resume and progress report reads:

```text
`packet:round <N> head=<head sha> tier=<tier> lenses=<a,b,c> confirmed=<lenses with confirmed findings> outcome=<pass|fix|needs-human>`
```

## 5 · Outcome

- **Pass**: no confirmed findings. Return Pass. The dispatcher checks CI on this head and hands off (its step 9); invoked directly, tell the owner `/packet-dispatch resume <ID>` hands it off. The panel never sets Ready to merge.
- **Fix**: confirmed findings and rounds left. Return the confirmed list (file:line, claim, reproduction, fix plan). The fixes land as one commit, `Round-<N> review fixes (<ID>)`, and the next round starts with this skill again.
- **Last round with confirmed findings:**
  - only should-fix: open one follow-up issue per finding before the report (§4) (`gh issue create --label <labels.followUp>`, linking the PR and the finding), list them in the report, and Pass. A contract finding's issue is titled `<ID> contract: <the question>` and also gets the `<labels.needsHuman>` label, so no dispatcher starts a packet that depends on this one while the label is on (packet-dispatch, Select). Its body names those packets and says how to clear it: answer on the issue, then remove the `<labels.needsHuman>` label (keep the issue open if the follow-up work remains) or close it. If `gh issue create` fails because a label doesn't exist, stop and tell the owner to create it (`board setup` does, for the GitHub and Azure Boards providers; with the local board, `gh label create <name> --repo <repo>`); never file the follow-up without its labels;
  - any blocking: **Needs human**: `board set <ID> "Status=Needs human"`, and comment on the item (first line `` `packet:needs-human` ``) with the finding and three options: the owner settles it on the PR (pushes or describes the fix, then posts `` `packet:settle` `` and resumes; the dispatcher verifies scope, tests and CI, with no further panel round), re-scopes it as a new packet, or merges with a follow-up issue.

Release your own claim (if you made one) as your last action. Never approve, request changes, merge or push.
