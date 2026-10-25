# What the kit costs on GitHub Copilot

This page estimates what the packet workflow costs in GitHub AI Credits, and how to run it on a limited team allowance, with 12,500 credits a month as the example.

The run counts per packet come from three sources: the kit's rules, the stage 5 end-to-end run, and 73 merged packets of the private project where the workflow started. The tokens per run are estimates. The end-to-end run used the owner's own API key, so Copilot billed nothing and nothing recorded tokens. [Calibrate](#calibrate) says how to replace the estimates with measurements.

**Written for four review tiers.** The figures on this page were worked out for the four-tier panel (1 light, 2 standard, 3 deep, 4 max) on the Opus 5.5 and Sonnet 5.5 classes. The panel now has three tiers, all on GPT-6.1 Sol: 1 light (low effort), 2 standard (medium) and 3 deep (high, the top). Tier 3 takes every diff that went to tier 4, with its adversarial remit, so where this page says tier 4, read tier 3. `budget.creditsPerRun.reviewerByTier` now lists three numbers, tier 3 at this page's tier-4 rate (a four-number list from an older install still works: its third number is dropped), so a packet whose rounds ran at the old tier 3 estimates higher than the tables below. The tables haven't been recalculated.

**In short.**

- **Defaults.** A packet that takes the usual three review rounds costs about 1,900 credits (S), 3,500 (M) or 6,300 (L). Averaged over a phase that is about 3,700 credits a packet.
- **What 12,500 buys.** About 3 packets a month, or one 10-packet phase every three months.
- **Budget profile.** It keeps every safety property and gets to about 5 packets a month.
- **Lean profile.** It trades some review strength for about 7 to 8.
- **Fit.** The pool fits a steady trickle of packets, not a phase a month. A phase a month needs paid usage above the pool, or the kit on the team's own API key.

## What a credit is

Since 1 June 2026, Copilot Business and Enterprise bill in **GitHub AI Credits**:

| Fact | Value |
| --- | --- |
| One credit | US$0.01. 12,500 credits is **US$125 a month**. |
| What it meters | Tokens: input, cached input, cache write and output (reasoning included), at each model's listed rate. Not requests. |
| Included | 1,900 credits per Business seat a month, 3,900 per Enterprise seat. 12,500 is about 6½ Business seats' allowance. |
| Pooling | One pool per billing entity. It resets on the 1st (UTC), and unused credits don't carry over. |
| What draws on it | Chat (agent mode included), Copilot CLI, the cloud agent, Spaces, Spark and third-party agents: so the kit and everything else the team does in Copilot. Completions and next-edit suggestions are free. |
| When the pool runs out | Paid usage at the same rates continues, unless an admin turned off the *AI credits paid usage* policy (it is on by default). User and cost-center budgets can cap it. There is no fallback to a cheaper model. |
| Your own API key (BYOK) | Billed by the provider, not drawn from the pool (secondary source; check with your admin). The end-to-end run worked this way. |

**Premium-request multipliers** no longer apply to these models. They survive only for annual Pro and Pro+ plans still on request-based billing. Those plans don't get new models, and their table lists none of the models in `models` (for example Claude Opus 4.8 is 27, Claude Sonnet 4.6 is 9, Claude Haiku 4.5 is 0.33). For this kit, the per-token rates below are what counts.

This page assumes all 12,500 credits go to the kit, and that the models in `models` are Copilot-hosted (not BYOK). It also assumes the first choice in each class is available, and that MCP servers are off in the packet sessions.

Sources, read 2026-10-20:

- [GitHub Copilot is moving to usage-based billing](https://github.blog/news-insights/company-news/github-copilot-is-moving-to-usage-based-billing/)
- [Usage-based billing for organizations and enterprises](https://docs.github.com/copilot/concepts/billing/usage-based-billing-for-organizations-and-enterprises)
- [Models and pricing](https://docs.github.com/copilot/reference/copilot-billing/models-and-pricing)
- [Model multipliers for annual plans (legacy)](https://docs.github.com/en/copilot/reference/copilot-billing/request-based-billing-legacy/model-multipliers-for-annual-plans)
- [Claude Sonnet 5.5 in GitHub Copilot](https://github.blog/changelog/2026-09-28-claude-sonnet-5-5-in-github-copilot)
- On BYOK: [Bring your own key](https://docs.github.com/en/copilot/concepts/models/bring-your-own-key), and the secondary [Northwestern IT guide](https://services.northwestern.edu/TDClient/30/Portal/KB/Article/2950/Managing-Your-GitHub-Copilot-Business-Usage)

## Rates for the models in `models`

US$ per million tokens, from *Models and pricing*:

| Model | Kit class | Input | Cached input | Cache write | Output | Against Sonnet 5.5 |
| --- | --- | --- | --- | --- | --- | --- |
| Claude Opus 5.5 | strong (1st) | 4.00 | 0.20 | 5.00 | 20.00 | 2× |
| GPT-5.6 Sol (≤ 272K context) | strong (2nd); standard (2nd) before this version | 4.00 | 0.40 | 5.00 | 20.00 | 2×, cache reads 4× |
| Claude Sonnet 5.5 | standard (1st), light (1st) | 2.00 | 0.10 | 2.50 | 10.00 | 1× |
| GPT-5.6 Luna (≤ 200K) | light (2nd) | 0.20 | 0.02 | 0.25 | 1.20 | about 0.1× |
| GPT-6.1 Sol | standard (2nd), from this version | 2.00 | 0.10 | 2.50 | 10.00 | 1× |
| Claude Haiku 5.5 (≤ 100K; above, 5×) | – | 0.10 | 0.01 | 0.125 | 0.50 | 0.05× |

In credits: a million Opus 5.5 output tokens cost 2,000 credits, and a million cache reads cost 20.

Two things in the template, as this page found it, cost more than they need to:

- **The standard fallback was GPT-5.6 Sol, which costs as much as Opus 5.5.** Where Sonnet 5.5 wasn't offered, the implementer and the standard reviewer quietly cost twice as much. This version falls back to GPT-6.1 Sol, which has Sonnet 5.5's rates.
- **The light class is Sonnet 5.5.** That costs little in practice, because tier 1 is rare (below).

## How the kit spends tokens

Every run is a loop of model calls, and each call sends the whole context again:

- **Cache reads are cheap.** The part of the context that the previous call already sent is billed at the cached-input rate.
- **New tokens are written to the cache** at 1.25× the input rate. That is Anthropic's price for its five-minute cache, so this page assumes a five-minute cache.
- **The dispatcher rewrites its context after long waits.** While a subagent runs, the dispatcher makes no calls. If the subagent outlives the cache, the dispatcher's next call writes its whole context again.
- **Output is the dearest token.** It costs five times input, and it includes reasoning.

Runs per packet, by role:

| Role | Runs | Model (default) |
| --- | --- | --- |
| Dispatcher | 1 session, plus a `resume` session when CI is still running at hand-off (taken as half a session per typical packet) | strong |
| Implementer | 1, plus 1 per fix round, plus 1 per CI failure the packet caused | standard |
| Reviewers | the lenses of each round, added up over the rounds, each at that round's tier | tier 1: light; tier 2: standard; tiers 3 and 4: strong |
| `packet-plan` | 1 session per phase | the session's model, taken as strong |
| `packet-board` | about 2 sessions per phase (setup or sync) | taken as standard |
| `packet-progress` | when asked, taken as 2 per phase | taken as standard |

The token shapes assumed per run:

| Run | Model calls | Fixed prompt | Context added per call | Output per call |
| --- | --- | --- | --- | --- |
| Dispatcher | 80 (one clean round) to 190 (three rounds, L) | about 21K | 0.3K–2.5K; it reaches the 200K window by round 3 | 150 tokens + 400 reasoning, plus the brief, the subagent prompts and the round reports |
| Reviewer, tier 4 | 34 for S, ×1.3 for M, ×1.6 for L; 15% fewer in later rounds | 12K + a 3K–4K prompt | 2K–3K | 200 + 1,400 reasoning |
| Reviewer, tier 3 / 2 / 1 | 26 / 22 / 12, scaled the same way | the same | the same | 200 + 700 / 800 / 300 reasoning |
| Implementer, first run | 55 / 90 / 140 (S / M / L) | 13.5K + the brief (3K–5K) | 1.4K | 350 + 400 reasoning |
| Implementer, fix run | 22 / 30 / 40 | + 1.5K of findings | 1.4K | 350 + 400 reasoning |

The cache rewrites come in two cases. After an implementer run the dispatcher rewrites its whole context every time. After a reviewer pair it does so half the time, since a pair takes about the five-minute cache lifetime.

**A check on the shapes.** Stage 5 took 50 minutes from the brief (21:09 UTC) to the hand-off (21:59 UTC). In that time it ran three implementer runs, five reviewer pairs and the dispatcher's own calls. That fits the call counts above; three times as many would not fit.

Credits per run that follow from these shapes:

| Run | S | M | L |
| --- | --- | --- | --- |
| Reviewer, tier 1 light (Sonnet 5.5, medium) | 20 | 30 | 40 |
| Reviewer, tier 2 standard (Sonnet 5.5, high) | 50 | 70 | 95 |
| Reviewer, tier 3 deep (Opus 5.5, medium) | 110 | 160 | 225 |
| Reviewer, tier 4 max (Opus 5.5, high) | 195 | 280 | 380 |
| Implementer, first run | 105 | 200 | 355 |
| Implementer, fix run | 40 | 55 | 75 |
| Dispatcher, one round, no findings | 380 | 490 | 575 |
| Dispatcher, three rounds | 1,170 | 1,360 | 1,640 |
| Dispatcher `resume` session | 80 | 80 | 80 |

Per phase: `packet-plan` about 400 (5 packets), 550 (10) or 900 (20); a board or progress session 15–20.

## One packet

Typical counts come from the original project's 73 merged packets, which ran the same panel under Claude Code:

| Original project, 73 packets | Value |
| --- | --- |
| Rounds | 1: 8 packets, 2: 12, 3: 53. 73% used all three. |
| Reviewer runs per packet | 6.6 on average; 4.8 under 500 changed lines, 11 above 1,500 |
| Lens runs that confirmed a finding | 365 of 481 (76%) |
| Round-1 fix rounds with a blocking finding | 21 of 65 |
| Round-2 fix rounds with a blocking finding | **9 of 53**; the other 44 had only should-fix findings |
| Round-3 outcomes | 46 pass, 7 Needs human |

The original project's tier settings put 96% of its reviewer runs at tier 4. So the tiers below come from the kit's own thresholds instead:

- **S** (about 150 lines of logic, plus tests and a decision record, about 300 lines) starts at tier 2. With a shared touchpoint it starts at tier 3, because it touches two subsystems.
- **M** (above 300 lines) starts at tier 3.
- **L** (above 1,000 lines) starts at tier 4.
- **Every round whose fixes answer confirmed findings goes up one tier.** So a packet that needs fixing almost always ends on the strong model.

Credits per packet under the defaults:

| Packet | Rounds (tiers) | Lenses per round | Reviewer runs | Implementer runs | Dispatcher | Reviewers | Implementer | Resume | **Total** |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| S, best case | 1 (2) | 2 | 2 | 1 | 380 | 100 | 105 | – | **580** |
| S, typical | 3 (2, 3, 4) | 3, 2, 1 | 6 | 3 | 1,170 | 500 | 185 | 40 | **1,890** |
| M, best case | 1 (3) | 3 | 3 | 1 | 490 | 480 | 200 | – | **1,170** |
| M, typical | 3 (3, 4, 4) | 4, 3, 2 | 9 | 3 | 1,360 | 1,830 | 310 | 40 | **3,540** |
| L, best case | 1 (4) | 4 | 4 | 1 | 575 | 1,530 | 355 | – | **2,460** |
| L, typical | 3 (4, 4, 4) | 5, 4, 3 | 12 | 3 | 1,640 | 4,130 | 510 | 40 | **6,310** |
| Stage 5 (PKT-1), as run | 3 (4, 4, 4) | 4, 3, 1 | 8 | 3 | 1,240 | 1,440 | 185 | – | **2,870** |
| Stage 5 without `ci.yml` | 3 (2, 3, 4) | 4, 3, 1 | 8 | 3 | 1,240 | 640 | 185 | – | **2,070** |

"Best case" is one clean round. "Typical" is three rounds with two fix runs, the original project's most common path. Each figure is rounded on its own, so a row's parts can miss its total by up to 10.

**Stage 5 calibration.** PKT-1 went to tier 4 only because it added `.github/workflows/ci.yml`, a review-machinery path. Without that file the same diff (227 lines, 6 files, one code subsystem) starts at tier 2, and the +1 rule lifts it to 3, then 4. The CI file cost that packet about 800 credits, 28% of its total.

Where the credits go in a typical M packet:

- **Reviewers, 52%.** The strong model runs nine reviewer runs in ten across a phase: of 87 runs, 52 are at tier 4, 26 at tier 3 and 9 at tier 2.
- **Dispatcher, 38%.** About two thirds of its credits carry its long context. Re-reading it is about a third of the dispatcher's credits, and rewriting it after subagent waits is another third. Output is the rest.
- **Implementer, 9%.**

**Range.** The per-run shapes are estimates. With 0.6× the calls and half the reasoning, the per-packet figures fall to about 0.6× of the table. With 1.5× both, they rise to about 1.75×.

## One phase and one month

A phase of N packets, mixed 30% S, 50% M and 20% L, all typical, under the defaults:

| Phase | Packets | `packet-plan`, board, progress | **Total** | Months of 12,500 |
| --- | --- | --- | --- | --- |
| 5 packets (2 S, 2 M, 1 L) | 17,200 | 450 | **17,600** | 1.4 |
| 10 packets (3 S, 5 M, 2 L) | 36,000 | 600 | **36,600** | 2.9 |
| 20 packets (6 S, 10 M, 4 L) | 71,900 | 1,000 | **72,900** | 5.8 |

Each figure is rounded on its own, so the parts can miss the total by up to 100.

**Per packet, all in: about 3,660 credits (US$37). 12,500 credits a month is about 3.4 packets**, somewhere between 2 and 6 given the range above. Planning, board and progress sessions are under 2% of a phase. The packets are the cost.

## Levers

Each lever is measured alone, against the 10-packet phase above (36,600 credits). They are grouped by how much quality they cost for the credits they save.

The safety column covers the four properties that must hold:

- the tier is a floor;
- markers count only from trusted authors;
- CI must pass on the reviewed head;
- only the owner merges.

**Free: no quality lost**

| Lever | Saves | Quality lost | Safety | Change |
| --- | --- | --- | --- | --- |
| Turn MCP servers off in packet sessions | 14% if they were on (5,200) | none | none | Workspace setting. The end-to-end dispatcher showed Copilot's 128-tool warning, which means about 30K of tool schemas in every call. |
| Put CI workflows and other machinery in the owner's setup PR (or a human task), not in a packet | 28% of the packet that would own them (800 in stage 5); about 2% of a phase | none | none: the owner reviews machinery directly, and a packet that still owns it still gets tier 4 | `packet-plan` rule |
| Standard fallback GPT-6.1 Sol instead of GPT-5.6 Sol | nothing while Sonnet 5.5 is offered; avoids +17% (6,100) when it isn't | none | none | config |
| Subagent prompts name trusted files instead of pasting them; test and CI logs trimmed to the summary and failures | 3% (1,150) | none | small: the reviewer must read the trusted lens, not the checkout's; the prompt gives it the exact `git show` command | skill text |
| `maxParallelLenses` 3 or 4 | 2% or 3%, through fewer dispatcher waits; next to nothing once lenses are grouped (below) | none; faster | none | config; the harness may still run them one at a time |

**Good trades**

| Lever | Saves | Quality lost | Safety | Change |
| --- | --- | --- | --- | --- |
| **From round 2, a round with only should-fix findings passes** and opens follow-ups, as the last round already did. A blocking finding still gets a fix and another round (in the last round it goes to the owner, as before). | 20% (7,300) | low to medium: should-fix findings found from round 2 on become follow-up issues instead of in-PR fixes; in the original project that would have ended 44 of 53 second rounds | none: tier, trust, CI and merge unchanged | kit: `review.shouldFixPassFromRound` |
| **Two lenses per reviewer run.** Every lens still runs, at the round's tier; one reviewer reads the diff once for both. | 16% (5,800) | low to medium: a reviewer splits its attention between two questions | none | kit: `review.lensesPerReviewer` |

**Mixed: real savings, some review strength lost**

| Lever | Saves | Quality lost | Safety | Change |
| --- | --- | --- | --- | --- |
| Dispatcher on the standard class | 19% (7,000) alone; 4,500 on top of the budget profile | medium: the brief's facts, and triage of strong-model findings, on a lighter model | none of the four directly, but in the Local harness a subagent won't start on a model in a higher cost tier than the session's, so tier 3 and 4 reviewers may not start | kit: a per-agent model class in `install.ps1` |
| No +1 tier after a round whose fixes were all should-fix | 6% (2,100) | low to medium | **weakens the tier floor's re-review rule** | skill text |
| Deep (tier 3) reviewer on the standard class | 5% (1,900) | medium: cross-file tracing on the lighter model | **weakens what tier 3 means**: agent and remit kept, model lighter | kit: a per-agent model class |
| Raise the tier-3 line threshold from 300 to 800 | 9% (3,300) | medium: an M packet's first round runs on the standard model | **weakens the tier floor** | kit: thresholds in config (now constants in `review-scope.ps1`) |
| Don't count a declared touchpoint toward "two subsystems" | small (S packets with a touchpoint start at tier 2) | low: the one-line edit is still reviewed, and checked by `check-scope` | **weakens the tier floor** for those packets | kit: `review-scope.ps1` |

**Poor trades**

| Lever | Saves | Why not |
| --- | --- | --- |
| `maxRounds` 2 | 24% (8,800) | The should-fix rule gets 83% of this saving. With 2 rounds, a blocking finding in round 2 goes to the owner instead of the panel; that is 9 of 53 packets in the original project. |
| At most 3 lenses in round 1 and 2 after (or 2 and 1) | 17% (35%) | A lens that doesn't run finds nothing, and 76% of the original project's lens runs confirmed a finding. Grouping lenses saves almost as much and keeps them all. |
| Implementer on Claude Haiku 5.5 | 7% (2,600) | The implementer is 9% of the cost. More findings mean more rounds, which likely eat the saving, and contexts above 100K cost five times as much. |
| Light class on Haiku 5.5 or GPT-5.6 Luna | about 0 | Tier 1 needs a docs-only or tiny diff, so it is rare. Fine to do, but it saves nothing. |
| `packet-plan` on the standard class | 1% (270) | Ownership lines and contracts are the hardest judgement in the kit, and everything later trusts them. |
| A fresh dispatcher session per round (`resume`) | 4% (1,600) | It costs the owner one click per round. |
| Skip later-round lenses that had no findings | about 1% | The kit already runs only the lenses that confirmed a finding, plus those whose paths the fix touched: 16 of the original project's 291 later-round runs. Dropping those leaves a fix's new surface unreviewed by its lens. |
| Hold the panel until CI is green | negative | The dispatcher already runs `commands.ci` (when it is set) before the PR, and waiting adds a `resume` session (80) per packet. The cheap version is free: when CI has already failed on the head under review, add the failure to that round's fixes rather than finding it after the pass. |

## Recommended budget profile

The profile keeps all four safety properties. Config values in `.github/packet-workflow.json`:

```json
{
  "models": {
    "strong": ["GPT-6.1 Sol (copilot)", "Claude Sonnet 5.5 (copilot)"],
    "standard": ["GPT-6.1 Sol (copilot)", "Claude Sonnet 5.5 (copilot)"],
    "light": ["GPT-6.1 Sol (copilot)", "Claude Sonnet 5.5 (copilot)"]
  },
  "review": {
    "maxRounds": 3,
    "maxParallelLenses": 2,
    "lensesPerReviewer": 2,
    "shouldFixPassFromRound": 2,
    "maxPaths": "",
    "deepPaths": ""
  },
  "budget": {
    "monthlyCredits": 12500,
    "creditsPerRun": {
      "dispatcher": 50, "dispatcherPerRound": { "S": 300, "M": 330, "L": 390 }, "dispatcherPerReviewerRun": 35,
      "implementer": { "S": 105, "M": 200, "L": 355 },
      "implementerFix": { "S": 40, "M": 55, "L": 75 },
      "reviewerByTier": { "S": [20, 50, 195], "M": [30, 70, 280], "L": [40, 95, 380] },
      "laterRoundFactor": 0.85
    }
  }
}
```

Check the model names against your picker. Then run `install.ps1` again, so the agents' `model:` lines change. Leave `budget.creditsPerRun` out to use the defaults shown, and replace them once you have measured.

How `progress.ps1 -Credits` prices a packet from its round markers:

- **Base:** `dispatcher` + `implementer`. This covers preflight, the brief, the PR and the hand-off, plus the first implementer run.
- **Each round:** `dispatcherPerRound` + `dispatcherPerReviewerRun` × runs + the reviewers + `implementerFix` if the round was a fix round.
- **Reviewers:** each run costs `reviewerByTier`, with a run of n lenses counting 1 + 0.4 (n − 1). From round 2 on, the reviewer cost is multiplied by `laterRoundFactor`.

The defaults are fitted to the model on this page. They reproduce its typical S, M and L packets within 1% and its one-round packets within 10%. `progress.ps1 -Credits` doesn't count `resume` sessions or CI-fix runs, which leave no marker (about 40 credits a typical packet).

The kit changes behind the profile are in this version of the kit. Changes 1, 2 and 6 behave as before until the config sets them. Changes 3, 4 and 5 apply to every install:

| # | Change | Where | Saves | Tier floor | Trust | CI on reviewed head |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `review.shouldFixPassFromRound` (default `maxRounds`: only the last round, as before). From that round on, a round whose confirmed findings are all should-fix passes and opens one follow-up per finding, contract questions included. A blocking finding still gets a fix and another round. | `packet-review/SKILL.md` §5, round report template, config template, README; config checks in `PacketWorkflow.ps1` | 20% | unchanged | unchanged | unchanged |
| 2 | `review.lensesPerReviewer` (default 1, at most 3). `review-scope.ps1` returns `Runs` (neighbouring lenses in `lensOrder`, grouped) and `Pairs` of runs, written `security+data`. The prompt names one or more lenses. The report table has a Run column, and the round marker records `runs=`. | `review-scope.ps1`, `packet-review/SKILL.md` §2 and §4, the four reviewer agents, round report template, tests | 16% | unchanged: every lens runs at the round's tier | unchanged | unchanged |
| 3 | Plan rule: CI workflows, agents, skills, instructions and the kit's config go in the owner's setup PR or a human task, not in a packet. | `packet-plan/SKILL.md` (a rule and an anti-pattern row) | 28% of such a packet | unchanged | unchanged | unchanged |
| 4 | Prompts name trusted sources instead of pasting them. The reviewer runs `git show <kit sha>:…` for its lens: the commit the kit was pinned from, with a project lens there taking precedence. It runs `git show <base>:<packet file>` for the packet. The implementer reads the brief from its temp file. Test and CI output go to a temp file, and only the summary and failures are read. | `packet-review/SKILL.md` Setup 6 and §2, `packet-dispatch/SKILL.md` Preflight 1, §5, §6.4, §8, Resume; reviewer and implementer agents | 3% | unchanged | the reviewer must run the commands it is given, never read the checkout's copy; the agents and the prompt say so | unchanged |
| 5 | The standard class falls back to GPT-6.1 Sol. | `templates/packet-workflow.json`, the implementer and standard reviewer agents | prevents +17% | – | – | – |
| 6 | A `budget` block, and `progress.ps1 -Credits`. It finds each packet's PR and reads its trusted round markers (tier, lenses, `runs=`, fix rounds), then prices them with `creditsPerRun`. It reports per packet, the phase total, the average per finished packet, and this month against `monthlyCredits`. It is an estimate to calibrate, not a meter. | `PacketWorkflow.ps1` (`Get-PwCreditEstimate`, `Get-PwCreditSummary`), `github-common.ps1` (`Get-PwGhRounds`, now shared with `board rounds`), `progress.ps1`, `packet-progress/SKILL.md`, README, tests | – (visibility) | – | unchanged: only trusted markers count | – |
| 7 | README: links this page, documents the new keys, and says MCP servers cost credits in every call. | README | 14% if they were on | – | – | – |

One more change, for safety rather than credits: review-scope now reports the panel's limits (`Settings`: `maxRounds`, `shouldFixPassFromRound`, `maxParallelLenses`, `lensesPerReviewer`) from the config at the base. The panel uses those values, so a packet branch can't relax its own panel by editing the config.

On the sandbox's real markers, `progress.ps1 -Credits` estimates PKT-1 at 2,858 credits, against this page's 2,870.

The **lean profile** adds these trade-offs, each named. They are not built:

| # | Change | Saves on top, 10-packet phase | Trade-off |
| --- | --- | --- | --- |
| 8 | A per-agent model class written by `install.ps1`, for example `"models": { "agents": { "packet-dispatcher": "standard", "packet-reviewer-deep": "standard" } }` | 4,500 (dispatcher) + 1,350 (deep) | Tier 3 runs on a lighter model; the dispatcher's brief and triage do too. In the Local harness, check that tier 4 reviewers still start from a standard-class dispatcher. |
| 9 | Pass `-FixedConfirmed` only when a fixed finding was blocking | 1,450 | The tier floor no longer rises after should-fix-only fixes. |

Results:

| | Default | Budget | Lean |
| --- | --- | --- | --- |
| S packet, typical | 1,890 | 1,240 | 750 |
| M packet, typical | 3,540 | 2,250 | 1,300 |
| L packet, typical | 6,310 | 4,060 | 3,520 |
| Stage 5 packet (PKT-1), as run | 2,870 | 1,880 | 1,510 |
| 10-packet phase, all in | 36,600 | 23,700 | 16,400 |
| Per packet, all in | 3,660 (US$37) | 2,370 (US$24) | 1,640 (US$16) |
| **Packets a month on 12,500** | **3.4** (2–6) | **5.3** (3–10) | **7.6** (4–15) |
| 10-packet phase, in months of 12,500 | 2.9 | 1.9 | 1.3 |

Applied in order, the budget profile's steps save:

1. Two lenses per reviewer run: 5,800.
2. Should-fix-only rounds pass from round 2: 6,300 more.
3. Prompts name files and logs are trimmed: 800 more.

Moving CI files to the setup PR comes on top for any packet that would have owned them.

## Running it within the pool

- **Decide the kit's share.** The 12,500 credits pay for everyone's chat, CLI and agent use too. At 2,400 credits a packet, giving the kit 8,000 a month means about three packets.
- **Prefer a cost-center budget with paid usage allowed** over a hard user budget. A user who runs out of budget loses Copilot in the middle of a run, with no fallback model. The packet's claim then lasts out its 30-minute lease, and `resume` repeats the interrupted round. Paid usage is billed at the same rate: a 10-packet phase under the budget profile is about US$240, against the US$125 included.
- **Start the costly packets early in the month.** An L packet under the budget profile is about 4,000 credits, a third of the pool.
- **Your own API key** keeps the kit out of the pool entirely. The end-to-end run worked this way. Check with your admin whether enterprise BYOK is allowed.
- **Keep packets M-sized and in one area.** Overhead per packet (preflight, brief, PR, hand-off) is about 350 credits. Above 1,000 lines, every round runs at tier 4 with more lenses, so an L packet costs about 1.8× an M one.

## Calibrate

The token shapes are the biggest guess on this page. Replace them as soon as there is data:

1. **Stage 5, already run.** In the API key's usage console, read 2026-10-19 from about 20:55 to 22:05 UTC: the brief was posted at 21:09:36Z and the hand-off at 21:59:21Z. Opus 5.5 tokens there are the dispatcher plus eight tier-4 reviewer runs; Sonnet 5.5 tokens are the three implementer runs. This is accurate only if nothing else used the key in that window.
2. **The first packets on Copilot-hosted models.** Run one dispatcher a day. Then download the AI usage report from the billing settings. It totals credits by date, model and user, and since August 2026 it also shows input, output, cache-read and cache-write tokens per model ([Visual Studio Magazine](https://visualstudiomagazine.com/articles/2026/08/13/big-copilot-bills-github-now-lets-you-peek-into-per-model-token-usage.aspx), secondary). The day's totals are then one packet's cost.
3. Divide by the run counts from `board rounds <pr>` and the fix commits, and update `budget.creditsPerRun` and this page.
