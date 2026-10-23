---
name: packet-review
description: "Review a packet's pull request with a panel of lenses. Each round runs only the lenses that fit the packet and the change, at most review.maxParallelLenses (2) reviewer runs at a time, on the reviewer tier the diff calls for, for at most three rounds. Triages every finding against the code, posts one round report on the PR, and returns Pass, Fix or Needs human. Use when a dispatcher reaches review, or when asked to review or re-review a packet PR."
argument-hint: "<PR number>"
---

# Review panel

A **lens** is a narrow review brief ([lenses/](./lenses/)). Each lens runs as its own read-only reviewer agent on the same head commit. You, the panel owner, pick the lenses and the tier, triage what the reviewers report, and post the round. The dispatcher applies fixes between rounds; the panel never edits code, pushes, approves or merges.

Commands run from the repository root. Kit scripts run only from a **pinned kit** (`<kit>`): the dispatcher's, when it invoked you, or your own, made exactly as the packet-dispatch skill's Preflight step 1 makes it, before any kit script runs. Never run the checkout's copies: the PR under review can change them. `board …` is `pwsh -File <kit>/.github/skills/packet-board/scripts/board.ps1 …`.

## The limits

1. **Lenses per round:** only the ones this round calls for (§1), never every lens by default, and never fewer.
2. **Lenses per reviewer run:** `review.lensesPerReviewer` (1). With 2 or 3, one reviewer run covers that many neighbouring lenses, as review-scope groups them (`Runs`); every lens still runs.
3. **Concurrency:** at most `review.maxParallelLenses` (2) reviewer runs at once. A **pair** is the runs started together: launch them, wait for all of them, then the next pair.
4. **Rounds:** at most `review.maxRounds` (3) per PR. Nothing changed after the last round merges unreviewed. From round `review.shouldFixPassFromRound` on (by default the last round), a round whose confirmed findings are all should-fix passes with follow-ups (§5).
5. **Tier floor:** every lens runs on the reviewer agent for the round's tier (§1), or a higher one. Never lower.

These settings come from review-scope's `Settings` (§1), which reads the config at the base, never from the PR's checkout: a packet branch can't relax its own panel.

## Setup

1. **The PR and its packet.** `gh pr view <pr> --json number,title,headRefName,headRefOid,baseRefName,state`. The packet ID is the title's prefix (`<ID>: …`) or the branch's (`pkt/<id>-…`). `board get <ID>` must find its item.
2. **The round number** comes from the PR's history, never from memory: `board rounds <pr>` lists the round reports (it reads only reports posted by trusted authors: the signed-in user and the config's `trustedAuthors`); this round is one more than the last. If that is past `maxRounds`, don't run a round (`Settings.MaxRounds` from §1's review-scope command, which you can run before this check; never the checkout's config): the packet needs the owner, who can settle it (the packet-dispatch skill's **Settle**).
3. **The checkout.** The reviewers read this checkout, so it must sit at the PR's head with no local changes: `git fetch origin`, `git status --porcelain` empty, `git rev-parse HEAD` equal to `headRefOid` (a dispatcher is already there; invoked directly, use `gh pr checkout <pr>` in a clean worktree). Note the head SHA.
4. **The claim.** Check it with `board claim <ID> <claim-id>` now (step 5 may write the status), before each pair and before the report, and nowhere else. That command decides when to renew: it posts a claim comment only when one is due and otherwise just confirms the hold (the packet-dispatch skill, step 2), so never add `-Force`. From a dispatcher: use its claim id; the dispatcher doesn't check again before the round. Invoked directly: make your own (`board new-claim-id`, `board claim`), check it the same way, and release it when you finish. `LOST` or exit 2 at any check: stop the round with no report. A round is reported whole or not at all.
5. **Status.** If the item shows Ready to merge, the head moved after a pass: `board set <ID> "Status=In review"` before the round starts.
6. **Lens texts come from trusted copies:** the kit's from the commit the kit was pinned from (`<kit sha>`, the packet-dispatch skill's Preflight step 1), a project lens from the default branch at that commit, never from the PR's checkout. A project lens overrides the kit's lens of the same name. For each lens, note the command that prints it: `git show <kit sha>:<paths.lenses>/<lens>.md` when that file exists there, otherwise `git show <kit sha>:.github/skills/packet-review/lenses/<lens>.md`. Reviewers run these commands themselves (§2). The scripts read the config at the base on their own.

## 1 · Tier and lenses

```bash
pwsh -File <kit>/.github/skills/packet-review/scripts/review-scope.ps1 -Base origin/<baseRefName> -Head <head sha> -Packet <ID> -Json
```

For rounds 2 and later add what the previous round's report says: `-Since <its head> -PreviousTier <its tier>`, and, when its outcome was `fix`, `-Confirmed <its confirmed=, as written, e.g. security,data>` and `-FixedConfirmed` (the commits since then fix those findings). After a round that **passed** (a CI fix, a conflict resolution or a re-targeted stack brings the PR back), pass `-Confirmed -` and no `-FixedConfirmed`: its should-fix findings went to follow-up issues and were left unfixed on purpose, so the new round reviews what changed, not those findings.

It returns `Tier`, `Agent`, `Reasons`, `Lenses` (riskiest first), `Runs` (the lenses each reviewer run covers), `Pairs` (the runs started together, each written as its lenses joined with `+`) and `Settings` (the limits above, from the config at the base). The tier is a **floor**: it measures the diff (size, files, subsystems, migrations, contracts, auth, infrastructure, concurrency, review machinery, the project's critical paths), applies the packet's **Review tier** line, and for later rounds keeps the previous tier, plus one after confirmed findings were fixed, up to tier 3, the top. You may raise it with a reason (say, the change can lose data or money); never lower it. Exit 3: nothing changed, so there is no round. Exit 2: stop and report; never guess a tier.

| Tier | Agent | Effort | Remit |
| --- | --- | --- | --- |
| 1 light | `packet-reviewer-light` | low | light to standard: docs, renames, config values, tests only, each hunk read as a standard review would |
| 2 standard | `packet-reviewer-standard` | medium | standard to deep: ordinary code in one area, traced into the code it calls and the code that calls it |
| 3 deep | `packet-reviewer-deep` | high | deep to max, the top tier: large or cross-cutting; migrations, contracts, auth, infra, concurrency, review machinery, critical paths; adversarial |

Round 1's lenses are the packet's **Review lenses** plus those the diff's paths call for (`review.lensPaths`, and concurrency patterns in added lines). Later rounds run only the lenses that confirmed a finding, plus those whose surface the new commits touched; a conflict resolution, or a merge of anything but the default branch, is always reviewed. A round never runs with no lens.

## 2 · Run the lenses, a pair at a time

Check the claim before each pair. For each pair (review-scope's `Pairs`), start the round's reviewer agent once per run, with that run's lens or lenses, all in one step if your harness runs subagents in parallel, otherwise one after the other. Wait until every run in the pair has answered before the next pair. Don't edit the checkout or push while a pair runs.

Reviewers run on the models their agent files pin. If your subagent tool asks for a model, or doesn't offer the pinned ones, use the model the owner named for the agent's class (the dispatcher asks once, in its Preflight; invoked directly, ask the owner yourself, before the first pair), never a weaker one, and put the model in the report's header.

Each reviewer gets this prompt, filled in. It names the packet and the lens texts by the commands that print them, rather than pasting them: the reviewer reads them itself, and the panel's own context stays small.

```text
Review tier: <tier> <name> (floor <floor>). Reasons: <review-scope reasons, plus any raise and why>
Lens: <lens>. <or, for a run of several:> Lenses: <a>, <b>. Take them one at a time.
Review only through <this lens / these lenses>; these lenses run separately this round: <the others>.
Packet: <ID> "<title>". PR #<pr>. Round <N> of <maxRounds>.
Checkout (read-only, do not edit): this repository at <head sha>.
Diff under review: git diff <base sha>...<head sha>
<rounds 2+:> Changes since round <N-1> (head <prev>): git log -p --first-parent --no-merges <prev>..<head sha>
  <each merge of the default branch with a conflict resolution:> git show --remerge-diff <merge sha>
  <each other merge:> git diff <merge sha>^1 <merge sha>
<rounds 2+, after a fix round only:> Findings <this lens / these lenses> confirmed last round, to check as fixed without regressions:
  <numbered list: lens, file:line, claim, reproduction>

Read these first, with exactly these commands, never from the files in this checkout (the PR can change those):
  The packet, from "## Goal" down: git show <base sha>:<packet file path>
  The lens<es>: <the command from Setup step 6, one per lens>

Project rules that bind this review: <repository instructions files>; guardrails: <guardrails.rules>.

Tag every finding blocking or should-fix, per its lens's Severity section<, and name its lens>. Anything
with neither a reproduction nor a consequence goes under "nits, not findings". Don't run test suites that
need shared services (a database, containers) unless the project's instructions say it is safe. Don't call
board.ps1.
```

If a reviewer reports that it couldn't run one of those commands, run it yourself and give it the text in a new run; never let it fall back to the checkout's copy.

## 3 · Triage

When every lens has reported, triage. Reviewers can be wrong, so you check each finding:

1. **Merge duplicates** across lenses; keep the strongest reproduction.
2. **Verify** each against the code at the head: open the cited lines; if it gives a command or test, run it.
3. **Classify:** *confirmed* (blocking or should-fix; keep the reviewer's severity unless the evidence says otherwise, and say why) or *rejected* (with the file:line or output that disproves it). A real problem outside the packet's scope becomes a **follow-up**, not a fix in this PR.
4. **Already filed.** A finding that an earlier round of this PR already opened as a follow-up issue is neither fixed nor filed again, and doesn't count toward the round's outcome (§5), only when all three hold: it makes the same claim about the same lines, it is still should-fix, and those lines haven't changed since that round's head (`git diff <that round's head> <head> -- <file>` touches none of them). List it under Follow-ups with that issue's number. Otherwise it is a new finding with its own severity: a blocking one counts like any other, and its report links the earlier issue.
5. **Contract findings.** A confirmed finding that questions something under the packet's **Provides** (a name, a signature, or behaviour that later packets build on) is a *contract* finding: tag it `contract` in the report. If it isn't fixed in this PR, its follow-up is a decision for the owner before those packets start, not a note for later (§5).

## 4 · Report

Check the claim. When the round passes with follow-ups (§5), open them first, so the report lists them: if opening one fails, stop here, with no report. Then fill [round-report-template.md](./round-report-template.md) and post it as one PR comment: `gh pr comment <pr> --body-file <file>`. Its first line is the round marker, which every later round, resume and progress report reads:

```text
`packet:round <N> head=<head sha> tier=<tier> lenses=<a,b,c> runs=<reviewer runs> confirmed=<lenses with confirmed findings> outcome=<pass|fix|needs-human>`
```

`runs` is the number of reviewer runs the round started (the lens count when each run had one lens); `progress.ps1 -Credits` estimates from it.

## 5 · Outcome

- **Pass**: no confirmed findings. Return Pass. The dispatcher checks CI on this head and hands off (its step 9); invoked directly, tell the owner `/packet-dispatch resume <ID>` hands it off. The panel never sets Ready to merge.
- **Fix**: confirmed findings, rounds left, and either a blocking finding among them or this round comes before `Settings.ShouldFixPassFromRound`. Return the confirmed list (file:line, claim, reproduction, fix plan). The fixes land as one commit, `Round-<N> review fixes (<ID>)`, and the next round starts with this skill again.
- **Only should-fix findings, in round `Settings.ShouldFixPassFromRound` or later** (by default only the last round): the round passes with follow-ups.
  - Open one follow-up issue per finding before the report (§4) (`gh issue create --label <labels.followUp>`, linking the PR and the finding), list them in the report, and Pass. A contract finding's issue is titled `<ID> contract: <the question>` and also gets the `<labels.needsHuman>` label, so no dispatcher starts a packet that depends on this one while the label is on (packet-dispatch, Select). Its body names those packets and says how to clear it: answer on the issue, then remove the `<labels.needsHuman>` label (keep the issue open if the follow-up work remains) or close it. If `gh issue create` fails because a label doesn't exist, stop and tell the owner to create it (`board setup` does, for the GitHub and Azure Boards providers; with the local board, `gh label create <name> --repo <repo>`); never file the follow-up without its labels.
- **Last round with any blocking finding: Needs human**: `board set <ID> "Status=Needs human"`, and comment on the item (first line `` `packet:needs-human` ``) with the finding and three options: the owner settles it on the PR (pushes or describes the fix, then posts `` `packet:settle` `` and resumes; the dispatcher verifies scope, tests and CI, with no further panel round), re-scopes it as a new packet, or merges with a follow-up issue.

Release your own claim (if you made one) as your last action. Never approve, request changes, merge or push.
