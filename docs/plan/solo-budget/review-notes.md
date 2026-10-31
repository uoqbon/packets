# Review notes for the solo-budget phase

The phase itself is `plan.md` and `packets/` beside this file, in the kit's own format. This file holds what doesn't belong in a packet:

- the owner's decisions;
- what I found in the repository;
- the open questions, in detail;
- the risks;
- the cost workings.

**Checks run:**

- `validate-packets.ps1 -Phase solo-budget` reports 9 packets, 3 human tasks, **0 errors and 0 warnings**. This repository has no `.github/packet-workflow.json`, since it is the kit's source, not an install. To validate, pass the template with `repo` filled in as `-ConfigPath`.
- The offline suite on `main` (0.1.1) passes: 243 passed, 0 failed.

## Decisions (2026-10-31)

| # | Question | Decision | What changed in the plan |
| --- | --- | --- | --- |
| 1 | Which models the cost page assumes | GPT-6.1 Sol in every class | PKT-7 recalculates the page on GPT-6.1 Sol. It also moves the default `budget.creditsPerRun` to those rates: the dispatcher and tier 3 at half today's values. Without that, the page, `progress.ps1 -Credits` and the ceiling would price a packet differently. That re-pins about six existing test assertions on purpose. An existing config keeps the rates written in it. PKT-7 is now P0, and PKT-4 (the solo template copies its rates) depends on it. |
| 2 | `shouldFixPassFromRound` in the solo profile | 2 | none (already the plan) |
| 8 | How to build the phase | not with the kit | H-1 is gone. Packets are PRs you review; their Review lenses and Review tier lines say what that review should cover. The dates moved to start on 2026-11-02. |
| 9 | Pro's allowance | GitHub's individual billing page | PKT-8 cites it. The page gives Pro 1,500: 1,000 base credits plus a 500 "flex allotment" that GitHub says can change. Pro+ gets 7,000, and Max 20,000. Allowances reset at 00:00 UTC on the 1st and don't carry over. |
| 10 | Paid usage for calibration | OK | H-2 says so (about US$50). |
| 3 | What the cap leaves uncapped | as recommended: machinery, `deepPaths`, `maxPaths`, `.gitattributes`, a diff of only ignored files, the Review tier line; auth and migration stay capped | PKT-3 |
| 4 | The solo ceiling | as recommended: per size, S 1,000, M 1,500, L 2,200; Copilot CLI's session limit documented as a backstop | PKT-4, PKT-8 |
| 5 | Where the raise lives; what the fix check prices | as recommended: a PR comment that holds for the rest of the packet; the fix plus the cheapest round after it | PKT-5, PKT-6 |
| 6 | Plan-only mode | as recommended: `check-scope.ps1` installed on its own; the flag decides each run; `-PlanOnly` on a full install refused | PKT-2. A CI job for the scope check is a follow-up: it needs a rule for finding a PR's packet. |
| 7 | Widening the settle | as recommended: the narrow widening (7B) | PKT-6, PKT-8 |

**The rate change (decision 1's knock-on): OK.** PKT-7 moves the default `creditsPerRun` to GPT-6.1 Sol rates and re-pins about six existing tests. New installs estimate about half what 0.1.1 did; existing configs keep their rates. Nothing is left open.

## Findings that shaped the plan

1. **Every model class lists the same models.** `templates/packet-workflow.json:96-100` and all five agents' `model:` lines list GPT-6.1 Sol, then Claude Sonnet 5.5, in every class. With those lists, putting the dispatcher on the standard class saves nothing. The solo template still sets it, so the dispatcher stays put if `models.strong` later names a dearer model.
2. **The README's safety table has no "tier is a floor" row.** The phrase lives in `skills/packet-review/SKILL.md` and in cost.md's four properties. PKT-8 adds the row.
3. **The lens check needs a fallback in plan-only mode.** `validate-packets.ps1:219` finds the kit's lens names in `../../packet-review/lenses`, which a plan-only install doesn't have. PKT-1 adds `$script:KitLenses` and PKT-2 uses it.
4. **The removal loop could delete the dispatcher.** `install.ps1:145-156` would delete the dispatcher half on a careless `-PlanOnly`, so PKT-2 refuses one before the loop runs.
5. **"Three rounds" is written into the text** in five places, and PKT-3, PKT-6 and PKT-8 replace it with `review.maxRounds`.
6. **The dispatch skill's Never list doesn't name `packet:settle`.** Only the Settle section implies that the owner posts it. PKT-6 adds it, with `packet:budget`, to the Never list.
7. **Copilot CLI already has a real per-session credit limit.** It is `/limits set max-ai-credits <n>`, or `--max-ai-credits <n>` (public preview, soft, at least 30, CLI and SDK). It measures real spend but stops mid-step, so it complements the kit's ceiling. See question 4.

## Workstream 1: what plan, board and progress read from the config

None of `commands.*`, `models` and `review.*` is required: `Get-PwConfig` fills defaults for each. Plan-only mode still writes the full template, so a later full install has `review.lensPaths`.

| Key | Plan-only mode | Read by |
| --- | --- | --- |
| `repo` | **required** (owner/name, not `OWNER/REPO`) | every script |
| `board.provider` and its block | **required** for the chosen provider | board, progress |
| `defaultBranch`, `packetPrefix`, `humanPrefix`, `paths.plans` | used, with defaults | validator, board, progress |
| `paths.lenses`, the keys of `review.lensPaths` | used as lens names the validator accepts | validator |
| `locks`, `sizes`, `stacking`, `remotes`, `labels.*`, `trustedAuthors` | used, with defaults | validator, board, progress |
| `budget.*` | `progress.ps1 -Credits` only, which finds no round markers in this mode | progress |
| the other `review.*` keys, `claims.leaseMinutes` | not used, but **checked when present** (a bad regex or a non-number stops board and progress) | `Get-PwConfig` |
| `commands.*`, `guardrails.*`, `models`, `review.agents`, `review.lensOrder`, `paths.decisions` | not read | dispatch, review, install |

## Workstream 2: the Local harness

**What the host does.** VS Code's subagent docs, Local harness: "Explicit and agent-configured model selections are checked against the main model's cost tier. If a selection exceeds that tier, the subagent doesn't run and reports which models are available."

**What happens today.** A standard-class dispatcher session can't start a deep reviewer pinned to a dearer model. The dispatcher agent then tells you to switch the session's model. Preflight step 7 could also lead it to ask you for a lighter model per class.

**What the plan does:**

- **At install (PKT-4).** The installer warns about setups where this can happen.
- **Before the round (PKT-3).** review-scope flags it before the first pair.
- **At the refusal (PKT-6).** The round stops at Needs human (`reason=model-tier`), never on a lighter model.

With your answer to question 1 and the shipped lists, it can't happen until `models.strong` names a dearer model.

## Credits on GPT-6.1 Sol

**Method:** the same as cost.md's. I ran the kit's own `Get-PwCreditEstimate` on these inputs:

- **Rates.** The new default rates (PKT-7), plus a resume share of 20 on multi-round packets.
- **Lenses.** cost.md's lens counts: S 3 then 2, M 4 then 3, L 5 then 4.
- **Runs.** The lenses divided by 3, rounded up.
- **Rounds.** The share of one-round packets comes from the original project's 73 packets.
- **The phase.** 30% S, 50% M and 20% L, plus about 350 for planning, board and progress at Sonnet rates.

| Credits | S | M | L |
| --- | --- | --- | --- |
| Default, three tiers, typical (3 rounds) | 1,180 | 2,160 | 3,430 |
| **Solo, typical**: 2 rounds at tier 2 | **675** | **985** | **1,465** |
| Solo, one clean round | 370 | 535 | 875 |
| Solo, expected: 11% one round, 89% two | 640 | 935 | 1,400 |
| Solo without the cap | 730 | 1,290 | 1,995 |
| Solo, a packet forced to tier 3 | 815 | 1,290 | 1,995 |

Per packet all in, over a 10-packet phase:

- default: about **2,160**;
- solo: about **1,020** typical, or **975** expected;
- solo without the cap: about 1,300.

### Packets a month on one seat

Assuming the whole allowance goes to the kit; the ranges are cost.md's 0.6× to 1.75×.

| Seat (credits a month) | cost.md as it stands (3,660) | Default, three tiers (2,160) | **Solo (975 expected)** |
| --- | --- | --- | --- |
| Pro, 1,500 | 0.4 | 0.7 | **1.5** (0.9–2.6) |
| Business, 1,900 | 0.5 | 0.9 | **1.9** (1.1–3.2) |
| Enterprise, 3,900 | 1.1 | 1.8 | **4.0** (2.3–6.7) |
| Pro+, 7,000 (for reference) | 1.9 | 3.2 | 7.2 (4.1–12.0) |

**Plan and board only.** A 10-packet phase costs about 350 credits to plan, sync and track. That is about 4 phases a month on Pro, 5 on Business and 11 on Enterprise, before any hand-off.

## Decisions 3 to 7: the reasoning

### 3. What the tier cap leaves uncapped

**How the tier is set today** (`review-scope.ps1:257-297`). A round starts at tier 1 or 2 from the diff's size and kind. Then any of these raises it to 3:

- **size:** more than 300 lines, more than 8 files, or code in two or more subsystems;
- **sensitive paths:** migrations or schemas, API contracts, auth, or infrastructure;
- **concurrency** words in added lines (`async`, `await`, `Promise.all`, …);
- **the project's own paths:** `review.deepPaths` and `review.maxPaths`;
- **review machinery**, or a `.gitattributes` change;
- **a diff of only ignored files:** lockfiles, minified or generated output.

The packet's **Review tier** line can raise it further. A later round keeps the previous round's tier, and goes up one if fixes answered confirmed findings.

**What the cap trades.** With GPT-6.1 Sol in every class, tiers 2 and 3 run the same model. The cap takes away what tier 3 adds on top:

- the deep reviewer's remit: every producer and consumer traced, and an adversarial attempt to prove the change wrong;
- high reasoning effort instead of medium, where the harness honours it (the Copilot harness does);
- more calls per run.

**What it buys:** about 8% of an S packet, 24% of an M and 27% of an L. That moves a Business seat from about 1.5 to 1.9 packets a month. Each packet forced to tier 3 gives back +140 (S), +300 (M) or +530 (L).

**The three you named** (machinery, `deepPaths`, `maxPaths`) stay forced.

**The three I added:**

1. **A `.gitattributes` change.**
   - *Why force it:* attributes decide how git diffs, merges and exports files (`binary`, `-diff`, `text` and `eol`, `merge`, `export-ignore`). The tier's line counts, the scope check and the pinned kit (made with `git archive`, which obeys `export-ignore`) all go through those commands. review-scope already treats it like machinery (line 289).
   - *Cost:* nil in practice, since it changes perhaps once in a repository's life.
   - *If capped instead:* a PR that changes how its own diff is measured gets the standard reviewer.
2. **A diff of only lock or generated files.**
   - *Why force it:* review-scope leaves those files out when it measures, so a dependency bump measures as nothing; that is why it goes to tier 3 today. A lockfile can change where a package is fetched from (a `resolved` URL, an integrity hash): the supply-chain surface.
   - *When it applies:* only when the diff holds nothing else; a PR with code and a lockfile is measured on its code.
   - *Cost:* a dependency-bump S packet costs about 745 instead of 640.
3. **The packet's Review tier line.**
   - *Why force it:* it is your per-packet decision, written in the plan, approved in the plan PR, and read at the base, so a branch can't add or remove it. If the cap overrode it, a capped repository would have no per-packet way to ask for deep review, only `deepPaths`, a repository-wide regex. PKT-3's new plan-skill rule (give auth, migration, contract and concurrency packets `Review tier: 3`) rests on it.
   - *Cost:* the forced premium, on the packets the planner marks.

**Auth and migration: three ways.**

| Option | What it does | Cost |
| --- | --- | --- |
| **(a) Cap them** (recommended) | Deep review for these comes from the Review tier line (per packet, the planner's call, your approval) and `deepPaths` (per path, yours). | none beyond the packets marked |
| (b) Force both | The built-in patterns are broad by design. `session`, `token`, `permission` and `identity` match ordinary files (a `SessionList.tsx`, a `tokenizer.py`), and `(^|/)db/` matches any db folder. In a web app a large share of packets would be forced. | each forced packet the premium above; at 30% of packets forced, about +90 a packet, so Business goes from 1.9 to 1.7 |
| (c) Force migrations only | Migrations are rarer, and their mistakes (lost or corrupted data) are the hardest to undo. | a few packets per phase |

If you'd rather not rest on the planner's judgement for migrations, (c) is the one I'd add.

**One more design point.** A later round never drops below the previous round's tier, even if the reason that forced it has gone (say the fix reverted the deep-path change). That is what "the tier is a floor" means today, and I kept it.

### 4. The ceiling's values

**What it is for under the solo profile.** With `maxRounds` 2, a packet's review is already bounded: no third round, and a conflict or CI fix after round 2 goes to you. So the ceiling isn't there to stop runaway rounds. It does two things:

1. It stops before an unusual packet takes a large share of a small seat. An L packet forced to tier 3 with many lenses comes to about 2,500, more than a Pro month.
2. It turns "the seat ran dry mid-run" into a question at a step boundary. Today a user who runs out of budget loses Copilot mid-run, and the claim then holds until its lease runs out.

It is like a fuel warning that comes on while there's still a station nearby, rather than the engine cutting out halfway.

**Solo packets on GPT-6.1 Sol rates** (estimates, two rounds):

| Packet | S | M | L |
| --- | --- | --- | --- |
| typical, tier 2 | 675 | 985 | 1,465 |
| many lenses, tier 2 (M 6 then 4, L 8 then 6) | – | 1,120 | 1,720 |
| forced to tier 3, typical lenses | 815 | 1,290 | 1,995 |
| forced to tier 3, many lenses (S 5 then 3) | 1,005 | 1,535 | 2,485 |

**The options:**

| Option | Values | What trips it |
| --- | --- | --- |
| A. Off | – | nothing; you rely on the seat's allowance and budget |
| **B. Per size, about 1.5× typical** (recommended) | S 1,000, M 1,500, L 2,200 | only the last row: forced to tier 3 *and* many lenses |
| C. Per size, about 1.2× typical | S 800, M 1,200, L 1,800 | every packet forced to tier 3: you approve each deep packet's second round |
| D. One number for every size | e.g. 1,500 | can't be tight for S and loose for L at once: S and M never trip, a typical L sits at the edge |
| E. A share of the seat | e.g. 950 on Business | most M and L packets: too tight to be a default |

**A host backstop.** Copilot CLI's session limit (`--max-ai-credits`, or `/limits set`) measures real spend, not an estimate. But it stops wherever the session is, possibly mid-implementer run, with the claim held and the work uncommitted. So use it as a backstop above the kit's ceiling (for example ceiling + 50%) when dispatching from Copilot CLI. PKT-8 documents it. Not yet known: whether it counts the subagents' credits (H-4 checks this, with PKT-9's stage S11) and whether VS Code's Copilot harness honours it.

The values are in the estimator's units and uncalibrated. Revisit them after H-2.

### 5. Where the raise lives, and what the fix check prices

**5a. The raise.**

| | **PR comment `packet:budget max=<n>`** (recommended) | Board item comment | Config only |
| --- | --- | --- | --- |
| Read by | the same GitHub reader as rounds and settles | the board provider | `Get-PwConfig` at the base |
| Trusted authors | GitHub login plus `trustedAuthors` | GitHub logins, or Azure DevOps names on Azure Boards | whoever can merge to the default branch |
| Scope | this packet | this packet | every packet |
| Where you answer | on the PR, while the question is on the item: as with a settle today | on the item, beside the question | in a config PR |
| New failure modes | none | the round check needs the board: an Azure outage or an expired PAT stops a round (exit 2) | none |
| Shown by `board rounds` | yes | no | no |

**Config only has a timing problem.** The check reads the config at the PR's base, so a raise merged to the default branch reaches a packet only after its branch merges the default branch. It also raises every packet at once.

**In all three, the dispatcher could post the raise itself,** since it signs in as you, just as it can a settle. A forged raise spends credits; it can't pass a review. PKT-6 adds both markers to the Never list.

A raise holds for the rest of the packet, and the newest wins. The alternative is to tie each raise to the stop it answers (`stop=<comment id>`), so it can't carry over to a later surprise. That is a little more work; I'd keep it simple.

**5b. The fix check.** A quirk of the estimator first. `Get-PwCreditEstimate` books the fix run's cost on the round marker that says `outcome=fix`. When the dispatcher is about to run the fix, that marker is already posted, so "so far" already includes the fix. A check of "so far plus the fix run" therefore re-checks the previous round check, plus 40 to 75 credits.

**Worked example:** an M packet at tier 2, on GPT-6.1 Sol rates, with a ceiling of 900.

| Step | Estimate | Option A: price the fix run alone | **Option B: price the fix plus the cheapest round after it** (recommended) |
| --- | --- | --- | --- |
| Before round 1 | 621 | within | within |
| Round 1 confirms findings in 2 lenses; its marker books the fix | so far 676 | fix check: 676, within, so the fix runs and is pushed | fix check: 676 + round 2 with only the 2 confirmed lenses = 942, over: **stop before the fix** |
| Before round 2 (3 lenses: 2 confirmed, 1 for paths the fix touched) | 966 | over: **stop**, with a fix commit no panel has seen on the PR | – |
| Your options | | raise; review the fix yourself (needs question 7's full widening); or stop, and the fix run was wasted | raise; pass round 1's findings as follow-ups with nothing unreviewed on the PR (question 7); or stop, with nothing wasted |

B can still be overtaken, because the real round 2 may add lenses for paths the fix touched (966 against 942). So the round check stays, and can still trip after a fix, just less often. In short, B checks there's fuel for the drive back before you set out.

### 6. Plan-only mode: `check-scope.ps1`, and changing mode

**What `check-scope.ps1` does.** It compares every path a branch changed with the packet's Owns, touchpoints, decision record and locks, as merged on the default branch. It reports OUTSIDE, LOCKED, MACHINERY, TOUCH and DIRTY, and exits 0, 1 or 2. It is a script: no model, no credits.

**Why it matters for hand-offs.** In plan-only mode several packets can be in flight at once, some by hand and some with the coding agent. The plan's ownership lines are what keep them apart, and nothing else checks them in this mode. The coding agent sees Owns only as text in the issue body.

**How it would be installed:** the script alone, at `.github/skills/packet-dispatch/scripts/check-scope.ps1`, without the dispatch skill's `SKILL.md`. Copilot finds a skill by its `SKILL.md`, so no `/packet-dispatch` would appear. The script loads `../../packet-board/scripts/PacketWorkflow.ps1`, which the plan-only install has. A later full install adds the rest of the folder.

**How you'd run it.** On the PR's branch:

```bash
pwsh -File .github/skills/packet-dispatch/scripts/check-scope.ps1 -Packet PKT-3 -Base origin/main
```

It compares from the merge base, so `origin/main` is enough. A CI job that runs it on every PR is a follow-up: it needs a rule for finding a PR's packet, since a coding agent's PR title is free text.

**Cost to the phase:** one more file in PKT-2's install list, one test and a few README lines; PKT-2 stays M.

**I've changed my recommendation: install it.** It costs no credits and little work, and it is the only one of the kit's guards that still applies to a hand-off.

**Changing mode.** The manifest records `mode`.

| The repository has | You run | (i) The flag decides each run (recommended) | (ii) The mode is sticky |
| --- | --- | --- | --- |
| nothing | `-PlanOnly` | plan-only install | same |
| plan-only | `-PlanOnly` | upgrade the three skills | same |
| plan-only | the plain command | becomes full: adds the agents, the dispatch and review skills and the hook, and says so | stays plan-only, and says `-Full` adds the rest |
| full, or a 0.1.x manifest with no mode | the plain command | upgrade, as today | same |
| full | `-PlanOnly` | **refused**: writes nothing, and lists what a downgrade would remove | same |

- **The case for (i).** It has one rule: what you type is what you get. A teammate who runs the README's plain upgrade command makes the repository full, in a PR you review before it merges.
- **The case for (ii).** It prevents that, at the cost of a new flag and a mode you can only see in the manifest.
- **Why refuse a downgrade.** The removal loop deletes unchanged kit files, so a plan-only command pasted onto a full repository would delete the dispatcher, the reviewers, the dispatch and review skills and the hook. All in a PR, so recoverable, but a surprise. A real downgrade is rare: delete those folders in a PR, then run `-PlanOnly` (the README will say so), or add an explicit `-Downgrade` later.

### 7. Widening the settle

**What a settle does today.** It exists only once the rounds are used up:

1. You post `packet:settle head=<sha>` on the PR, after pushing your fix or with a change described.
2. The dispatcher fast-forwards to that head and applies a described change as one commit.
3. It re-runs the scope check and the tests, and checks CI.
4. It posts `packet:settle-check head=<sha>`. That head then counts as reviewed for the hand-off.

Your review stands in for the round that can't run.

**Why it comes up.** The ceiling's "pass with follow-ups" and the model-tier stop's "settle" both happen before the last round.

| Option | Budget stop before a fix | Budget stop before a round (after a fix) | Model-tier stop | What it weakens |
| --- | --- | --- | --- | --- |
| 7A. Widen fully (my first plan) | settle | settle (you review the fix) | settle | Code no panel saw (a fix, or the whole packet before round 1) can reach Ready to merge sooner, on your review. Under the cap, model-tier stops happen only on forced tier-3 rounds (machinery, deep or max paths, a Review tier 3 line), where deep review matters most, and 7A lets you settle those. |
| **7B. Narrow** (recommended now) | settle, at the panel-reviewed head, to pass the round's findings as follow-ups; it can't carry a change | raise or stop | run the round on its reviewer (a session on the stronger model, or the Copilot harness), or stop | nothing: no new way for unreviewed code to reach Ready to merge |
| 7C. Don't widen | raise or stop | raise or stop | switch, or stop | nothing, but a packet that is 90% done must spend more or be dropped |

**How 7B works.** Before the last round, a settle counts only when its `head` is the newest round's head and it describes no change. The dispatcher's Resume checks that. It needs one marker, and `board rounds` is unchanged.

**Why I've moved from 7A to 7B.** With 5b's option B, most budget stops happen before the fix, while the PR head is still the one the panel reviewed. So 7B covers the useful case without opening a path for unreviewed code. And model-tier stops sit exactly on the rounds that most need the deep reviewer.

**Blocking findings.** Under 7A or 7B, passing with follow-ups can pass blocking findings as issues. That is your call, as today's last-round option "merge with a follow-up issue" already is. The Needs human comment lists them.

**In short:** questions 4 (B), 5 (PR comment; B) and 7 (7B) are designed to fit together.

## Risks

The ones that touch a safety property come first.

1. **The cap weakens what the panel sees.** Under cap 2, these go to the standard reviewer at medium effort, without the deep remit:
   - auth, migrations, contracts, infrastructure and concurrency;
   - large or cross-cutting diffs.

   A round after fixes also no longer goes up a tier. Mitigations:
   - the cap is off by default;
   - the forced list (question 3);
   - the plan skill's Review tier rule;
   - "capped from 3" in every round report.
2. **The narrow settle (7B) lets you pass reported findings early.** Before the last round, a settle can pass the newest round's findings as follow-ups, at the head that round reviewed. No code a panel hasn't seen gets through this way.
3. **The dispatcher could forge raises and settles.** Any trusted identity can post `packet:budget` or `packet:settle`, the dispatcher's own included, since it signs in as you. A forged raise spends credits; a forged settle under 7B can only pass findings the panel reported. Mitigations: the Never lists, and a known-limitation line.
4. **The ceiling is an estimate, uncalibrated.** Resume sessions, CI-fix runs and pre-PR test reruns leave no marker (about 40 a packet). A failed estimate stops the packet (exit 2); it never passes it.
5. **The Local harness refuses dearer reviewers.** If a prioritized `model:` list falls back to a cheaper entry instead of refusing, a deep round could run on a cheaper model without a word. That can't happen while every class lists the same models; H-4 checks it, with PKT-9's stage S11.
6. **Two rounds send more to you.** About 15% of packets reach you with a blocking round-2 finding, against about 10% today.
7. **Three lenses per run splits a reviewer's attention.** The credit factor for three lenses is extrapolated.
8. **A plan-only hand-off skips the brief, the panel and the claim.** The scope check is installed, but runs only when someone runs it. The coding agent's credits aren't estimated. The Azure Boards integration sets the work item's status itself.
9. **The installer's removal loop can delete files.** A mode bug would delete the dispatcher half. PKT-2 refuses first, and a test shows nothing is removed.
10. **New default rates change new installs' estimates.** PKT-7's rates halve the estimates for new installs. Existing configs keep theirs, and the changelog (H-3) says how to move.
