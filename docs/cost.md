# What the kit costs on GitHub Copilot

This page estimates what the packet workflow costs in GitHub AI Credits, and how to run it on a limited team allowance, with 12,500 credits a month as the example.

The run counts per packet come from three sources: the kit's rules, the stage 5 end-to-end run, and 73 merged packets of the private project where the workflow started. The tokens per run are estimates. The end-to-end run used the owner's own API key, so Copilot billed nothing and nothing recorded tokens. [Calibrate](#calibrate) says how to replace the estimates with measurements.

**Models and tiers.** This page assumes GPT-6.1 Sol in every class, as the template lists it, and the three-tier review panel: 1 light (low reasoning effort), 2 standard (medium) and 3 deep (high, the top). A dearer strong class (Claude Opus 5.5 or GPT-5.6 Sol, twice GPT-6.1 Sol's rates) about doubles the dispatcher's and tier 3's parts.

**In short.**

- **Defaults.** A packet that takes the usual three review rounds costs about 1,190 credits (S), 2,165 (M) or 3,425 (L). Averaged over a phase that is about 2,160 credits a packet.
- **What 12,500 buys.** About 6 packets a month (5.8), or one 10-packet phase every 1.7 months.
- **Budget profile.** It keeps every safety property and gets to about 9 packets a month.
- **Lean profile.** On one model its trade-offs save only about 1% more, so it also gets to about 9.
- **Fit.** The pool fits a steady flow of packets: a 10-packet phase every month or two. Under the budget profile a 10-packet phase is about 14,100 credits, a little over the pool, so a phase every month still needs paid usage above the pool or the kit on the team's own API key.

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
| GPT-6.1 Sol | every class (1st) | 2.00 | 0.10 | 2.50 | 10.00 | 1× |
| Claude Sonnet 5.5 | every class (2nd) | 2.00 | 0.10 | 2.50 | 10.00 | 1× |
| Claude Opus 5.5 | – (strong, 1st, before 0.1.0) | 4.00 | 0.20 | 5.00 | 20.00 | 2× |
| GPT-5.6 Sol (≤ 272K context) | – (strong and standard, 2nd, before 0.1.0) | 4.00 | 0.40 | 5.00 | 20.00 | 2×, cache reads 4× |
| GPT-5.6 Luna (≤ 200K) | – (light, 2nd, before 0.1.0) | 0.20 | 0.02 | 0.25 | 1.20 | about 0.1× |
| Claude Haiku 5.5 (≤ 100K; above, 5×) | – | 0.10 | 0.01 | 0.125 | 0.50 | 0.05× |

GPT-6.1 Sol costs the same as Claude Sonnet 5.5, and half of Claude Opus 5.5, on every token type. In credits: a million GPT-6.1 Sol output tokens cost 1,000 credits, and a million cache reads cost 10.

Two things in the template, as this page first found it, cost more than they needed to. Both are history since 0.1.0 put GPT-6.1 Sol first in every class:

- **The standard fallback was GPT-5.6 Sol, which costs as much as Opus 5.5.** Where Sonnet 5.5 wasn't offered, the implementer and the standard reviewer quietly cost twice as much.
- **The strong class was Opus 5.5,** at twice the rates of every other class, for the dispatcher and the deepest reviewers.

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
| Reviewers | the lenses of each round, added up over the rounds, each at that round's tier | tier 1: light (low effort); tier 2: standard (medium); tier 3: strong (high) |
| `packet-plan` | 1 session per phase | the session's model, taken as strong |
| `packet-board` | about 2 sessions per phase (setup or sync) | taken as standard |
| `packet-progress` | when asked, taken as 2 per phase | taken as standard |

The token shapes assumed per run:

| Run | Model calls | Fixed prompt | Context added per call | Output per call |
| --- | --- | --- | --- | --- |
| Dispatcher | 80 (one clean round) to 190 (three rounds, L) | about 21K | 0.3K–2.5K; it reaches the 200K window by round 3 | 150 tokens + 400 reasoning, plus the brief, the subagent prompts and the round reports |
| Reviewer, tier 3 (high effort) | 34 for S, ×1.3 for M, ×1.6 for L; 15% fewer in later rounds | 12K + a 3K–4K prompt | 2K–3K | 200 + 1,400 reasoning |
| Reviewer, tier 2 / 1 (medium / low effort) | 22 / 12, scaled the same way | the same | the same | 200 + 800 / 300 reasoning: upper bounds, worked out at more reasoning than these efforts use |
| Implementer, first run | 55 / 90 / 140 (S / M / L) | 13.5K + the brief (3K–5K) | 1.4K | 350 + 400 reasoning |
| Implementer, fix run | 22 / 30 / 40 | + 1.5K of findings | 1.4K | 350 + 400 reasoning |

The cache rewrites come in two cases. After an implementer run the dispatcher rewrites its whole context every time. After a reviewer pair it does so half the time, since a pair takes about the five-minute cache lifetime.

**A check on the shapes.** Stage 5 took 50 minutes from the brief (21:09 UTC) to the hand-off (21:59 UTC). In that time it ran three implementer runs, five reviewer pairs and the dispatcher's own calls. That fits the call counts above; three times as many would not fit.

Credits per run that follow from these shapes, all on GPT-6.1 Sol:

| Run | S | M | L |
| --- | --- | --- | --- |
| Reviewer, tier 1 light (low effort; an upper bound) | 20 | 30 | 40 |
| Reviewer, tier 2 standard (medium effort; an upper bound) | 50 | 70 | 95 |
| Reviewer, tier 3 deep (high effort) | 98 | 140 | 190 |
| Implementer, first run | 105 | 200 | 355 |
| Implementer, fix run | 40 | 55 | 75 |
| Dispatcher, one round, no findings | 190 | 245 | 290 |
| Dispatcher, three rounds | 585 | 680 | 820 |
| Dispatcher `resume` session | 40 | 40 | 40 |

Tiers 1 and 2 keep the token shapes they were worked out with, at more reasoning than low and medium effort use, so their rates are upper bounds until they are measured. Tier 3 has the shape of the old four-tier panel's tier 4 (high effort), and the dispatcher and tier 3 cost half of what they did on Opus 5.5.

Per phase: `packet-plan` about 200 (5 packets), 275 (10) or 450 (20); a board or progress session 15–20.

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

The original project's tier settings put 96% of its reviewer runs at its tier 4 (today's tier 3). So the tiers below come from the kit's own thresholds instead:

- **S** (about 150 lines of logic, plus tests and a decision record, about 300 lines) starts at tier 2. With a shared touchpoint it starts at tier 3, because it touches two subsystems.
- **M** (above 300 lines) starts at tier 3, the top.
- **L** (above 1,000 lines) starts at tier 3 too.
- **Every round whose fixes answer confirmed findings goes up one tier,** up to tier 3. So a typical S packet runs at tiers 2, 3 and 3, and M and L packets stay at tier 3 throughout.

Credits per packet under the defaults:

| Packet | Rounds (tiers) | Lenses per round | Reviewer runs | Implementer runs | Dispatcher | Reviewers | Implementer | Resume | **Total** |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| S, best case | 1 (2) | 2 | 2 | 1 | 190 | 100 | 105 | – | **395** |
| S, typical | 3 (2, 3, 3) | 3, 2, 1 | 6 | 3 | 585 | 400 | 185 | 20 | **1,190** |
| M, best case | 1 (3) | 3 | 3 | 1 | 245 | 420 | 200 | – | **865** |
| M, typical | 3 (3, 3, 3) | 4, 3, 2 | 9 | 3 | 680 | 1,155 | 310 | 20 | **2,165** |
| L, best case | 1 (3) | 4 | 4 | 1 | 290 | 760 | 355 | – | **1,405** |
| L, typical | 3 (3, 3, 3) | 5, 4, 3 | 12 | 3 | 820 | 2,080 | 505 | 20 | **3,425** |
| Stage 5 (PKT-1), as run | 3 (3, 3, 3) | 4, 3, 1 | 8 | 3 | 620 | 725 | 185 | – | **1,530** |
| Stage 5 without `ci.yml` | 3 (2, 3, 3) | 4, 3, 1 | 8 | 3 | 620 | 535 | 185 | – | **1,340** |

"Best case" is one clean round. "Typical" is three rounds with two fix runs, the original project's most common path. A reviewer run in round 2 or 3 costs 0.85 of its rate (15% fewer calls), and the resume share is half of a 40-credit `resume` session. Each figure is rounded to the nearest 5 on its own.

**Stage 5 calibration.** PKT-1 ran every round at the top tier (tier 4 then, tier 3 now) only because it added `.github/workflows/ci.yml`, a review-machinery path. Without that file the same diff (227 lines, 6 files, one code subsystem) starts at tier 2, and the +1 rule lifts it to 3, where it stays. The CI file cost that packet about 190 credits, 12% of its total.

Where the credits go in a typical M packet:

- **Reviewers, 53%.** Tier 3 runs nine reviewer runs in ten across a phase: of 87 runs, 78 are at tier 3 and 9 at tier 2.
- **Dispatcher, 31%.** About two thirds of its credits carry its long context. Re-reading it is about a third of the dispatcher's credits, and rewriting it after subagent waits is another third. Output is the rest.
- **Implementer, 14%.**
- **Resume share, 1%.**

**Range.** The per-run shapes are estimates. With 0.6× the calls and half the reasoning, the per-packet figures fall to about 0.6× of the table. With 1.5× both, they rise to about 1.75×.

## One phase and one month

A phase of N packets, mixed 30% S, 50% M and 20% L, all typical, under the defaults:

| Phase | Packets | `packet-plan`, board, progress | **Total** | Months of 12,500 |
| --- | --- | --- | --- | --- |
| 5 packets (2 S, 2 M, 1 L) | 10,100 | 275 | **10,400** | 0.8 |
| 10 packets (3 S, 5 M, 2 L) | 21,200 | 350 | **21,600** | 1.7 |
| 20 packets (6 S, 10 M, 4 L) | 42,500 | 525 | **43,000** | 3.4 |

`packet-plan`, board and progress: `packet-plan` at the rates above (200, 275 or 450), plus four board or progress sessions at 15–20 each (about 75). The packets and the totals are rounded to the nearest 100 on their own, so the parts can miss the total by up to 100.

**Per packet, all in: about 2,160 credits (US$22). 12,500 credits a month is about 5.8 packets**, somewhere between 3 and 10 given the range above. Planning, board and progress sessions are under 2% of a phase. The packets are the cost.

## Levers

Each lever is measured alone, against the 10-packet phase above (21,600 credits). They are grouped by how much quality they cost for the credits they save.

The safety column covers the four properties that must hold:

- the tier is a floor;
- markers count only from trusted authors;
- CI must pass on the reviewed head;
- only the owner merges.

**Free: no quality lost**

| Lever | Saves | Quality lost | Safety | Change |
| --- | --- | --- | --- | --- |
| Turn MCP servers off in packet sessions | 14% if they were on (3,100) | none | none | Workspace setting. The end-to-end dispatcher showed Copilot's 128-tool warning, which means about 30K of tool schemas in every call. |
| Put CI workflows and other machinery in the owner's setup PR (or a human task), not in a packet | 12% of the packet that would own them (190 in stage 5); about 1% of a phase | none | none: the owner reviews machinery directly, and a packet that still owns it still gets tier 3 | `packet-plan` rule |
| GPT-6.1 Sol, not GPT-5.6 Sol, in the standard class (done: 0.1.0 lists GPT-6.1 Sol first in every class) | nothing now; GPT-5.6 Sol there would add about 6,100 (+28%) | none | none | config |
| Subagent prompts name trusted files instead of pasting them; test and CI logs trimmed to the summary and failures | 3% (700) | none | small: the reviewer must read the trusted lens, not the checkout's; the prompt gives it the exact `git show` command | skill text |
| `maxParallelLenses` 3 or 4 | 2% or 2.5% (350 or 550), through fewer dispatcher waits; next to nothing once lenses are grouped (below) | none; faster | none | config; the harness may still run them one at a time |

**Good trades**

| Lever | Saves | Quality lost | Safety | Change |
| --- | --- | --- | --- | --- |
| **From round 2, a round with only should-fix findings passes** and opens follow-ups, as the last round already did. A blocking finding still gets a fix and another round (in the last round it goes to the owner, as before). | 19% (4,100) | low to medium: should-fix findings found from round 2 on become follow-up issues instead of in-PR fixes; in the original project that would have ended 44 of 53 second rounds | none: tier, trust, CI and merge unchanged | kit: `review.shouldFixPassFromRound` |
| **Two lenses per reviewer run.** Every lens still runs, at the round's tier; one reviewer reads the diff once for both. | 16% (3,500) | low to medium: a reviewer splits its attention between two questions | none | kit: `review.lensesPerReviewer` |

**Mixed: real savings, some review strength lost**

| Lever | Saves | Quality lost | Safety | Change |
| --- | --- | --- | --- | --- |
| Dispatcher on the standard class | nothing while every class lists the same models; with a dearer strong class, the difference in the dispatcher's rates | medium, with a dearer strong class: the brief's facts, and triage of strong-model findings, on a lighter model | none of the four directly, but in the Local harness a subagent won't start on a model in a higher cost tier than the session's, so tier 3 reviewers may not start | kit: a per-agent model class in `install.ps1` |
| No +1 tier after a round whose fixes were all should-fix | 1% (230): S packets only, since M and L start at the top tier | low to medium | **weakens the tier floor's re-review rule** | skill text |
| Deep (tier 3) reviewer on the standard class | nothing while every class lists the same models; with a dearer strong class, the difference in tier 3's rates | medium, with a dearer strong class: cross-file tracing on the lighter model | **weakens what tier 3 means**: agent and remit kept, model lighter | kit: a per-agent model class |
| Raise the tier-3 line threshold from 300 to 800 | 6% (1,400) | medium: an M packet's first round runs at tier 2 | **weakens the tier floor** | kit: thresholds in config (now constants in `review-scope.ps1`) |
| Don't count a declared touchpoint toward "two subsystems" | small (S packets with a touchpoint start at tier 2) | low: the one-line edit is still reviewed, and checked by `check-scope` | **weakens the tier floor** for those packets | kit: `review-scope.ps1` |

**Poor trades**

| Lever | Saves | Why not |
| --- | --- | --- |
| `maxRounds` 2 | 23% (5,000) | The should-fix rule gets 83% of this saving. With 2 rounds, a blocking finding in round 2 goes to the owner instead of the panel; that is 9 of 53 packets in the original project. |
| At most 3 lenses in round 1 and 2 after (or 2 and 1) | 16% (33%) | A lens that doesn't run finds nothing, and 76% of the original project's lens runs confirmed a finding. Grouping lenses saves as much and keeps them all. |
| Implementer on Claude Haiku 5.5 | 12% (2,600) | The implementer is 14% of the cost. More findings mean more rounds, which likely eat the saving, and contexts above 100K cost five times as much. |
| Light class on Haiku 5.5 or GPT-5.6 Luna | about 0 | Tier 1 needs a docs-only or tiny diff, so it is rare. Fine to do, but it saves nothing. |
| `packet-plan` on the standard class | nothing while every class lists the same models | Ownership lines and contracts are the hardest judgement in the kit, and everything later trusts them. |
| A fresh dispatcher session per round (`resume`) | 4% (800) | It costs the owner one click per round. |
| Skip later-round lenses that had no findings | about 1% | The kit already runs only the lenses that confirmed a finding, plus those whose paths the fix touched: 16 of the original project's 291 later-round runs. Dropping those leaves a fix's new surface unreviewed by its lens. |
| Hold the panel until CI is green | negative | The dispatcher already runs `commands.ci` (when it is set) before the PR, and waiting adds a `resume` session (40) per packet. The cheap version is free: when CI has already failed on the head under review, add the failure to that round's fixes rather than finding it after the pass. |

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
      "dispatcher": 25, "dispatcherPerRound": { "S": 150, "M": 165, "L": 195 }, "dispatcherPerReviewerRun": 18,
      "implementer": { "S": 105, "M": 200, "L": 355 },
      "implementerFix": { "S": 40, "M": 55, "L": 75 },
      "reviewerByTier": { "S": [20, 50, 98], "M": [30, 70, 140], "L": [40, 95, 190] },
      "laterRoundFactor": 0.85
    }
  }
}
```

Check the model names against your picker. Then run `install.ps1` again, so the agents' `model:` lines change. Leave `budget.creditsPerRun` out to use the defaults shown, and replace them once you have measured. A config that already sets `creditsPerRun` keeps the rates written in it: the installer never rewrites a config, so copy these in to move an older install to GPT-6.1 Sol's rates.

How `progress.ps1 -Credits` prices a packet from its round markers:

- **Base:** `dispatcher` + `implementer`. This covers preflight, the brief, the PR and the hand-off, plus the first implementer run.
- **Each round:** `dispatcherPerRound` + `dispatcherPerReviewerRun` × runs + the reviewers + `implementerFix` if the round was a fix round.
- **Reviewers:** each run costs `reviewerByTier`, with a run of n lenses counting 1 + 0.4 (n − 1). From round 2 on, the reviewer cost is multiplied by `laterRoundFactor`.

The defaults are fitted to the model on this page. With the resume share added, they reproduce its typical S, M and L packets within 1%, and they reproduce its one-round packets within 10%. `progress.ps1 -Credits` doesn't count `resume` sessions or CI-fix runs, which leave no marker (about 20 credits a typical packet).

The kit changes behind the profile are in this version of the kit. Changes 1, 2 and 6 behave as before until the config sets them. Changes 3, 4 and 5 apply to every install:

| # | Change | Where | Saves | Tier floor | Trust | CI on reviewed head |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `review.shouldFixPassFromRound` (default `maxRounds`: only the last round, as before). From that round on, a round whose confirmed findings are all should-fix passes and opens one follow-up per finding, contract questions included. A blocking finding still gets a fix and another round. | `packet-review/SKILL.md` §5, round report template, config template, README; config checks in `PacketWorkflow.ps1` | 19% | unchanged | unchanged | unchanged |
| 2 | `review.lensesPerReviewer` (default 1, at most 3). `review-scope.ps1` returns `Runs` (neighbouring lenses in `lensOrder`, grouped) and `Pairs` of runs, written `security+data`. The prompt names one or more lenses. The report table has a Run column, and the round marker records `runs=`. | `review-scope.ps1`, `packet-review/SKILL.md` §2 and §4, the four reviewer agents, round report template, tests | 16% | unchanged: every lens runs at the round's tier | unchanged | unchanged |
| 3 | Plan rule: CI workflows, agents, skills, instructions and the kit's config go in the owner's setup PR or a human task, not in a packet. | `packet-plan/SKILL.md` (a rule and an anti-pattern row) | 12% of such a packet | unchanged | unchanged | unchanged |
| 4 | Prompts name trusted sources instead of pasting them. The reviewer runs `git show <kit sha>:…` for its lens: the commit the kit was pinned from, with a project lens there taking precedence. It runs `git show <base>:<packet file>` for the packet. The implementer reads the brief from its temp file. Test and CI output go to a temp file, and only the summary and failures are read. | `packet-review/SKILL.md` Setup 6 and §2, `packet-dispatch/SKILL.md` Preflight 1, §5, §6.4, §8, Resume; reviewer and implementer agents | 3% | unchanged | the reviewer must run the commands it is given, never read the checkout's copy; the agents and the prompt say so | unchanged |
| 5 | The standard class falls back to GPT-6.1 Sol. | `templates/packet-workflow.json`, the implementer and standard reviewer agents | prevents +28% | – | – | – |
| 6 | A `budget` block, and `progress.ps1 -Credits`. It finds each packet's PR and reads its trusted round markers (tier, lenses, `runs=`, fix rounds), then prices them with `creditsPerRun`. It reports per packet, the phase total, the average per finished packet, and this month against `monthlyCredits`. It is an estimate to calibrate, not a meter. | `PacketWorkflow.ps1` (`Get-PwCreditEstimate`, `Get-PwCreditSummary`), `github-common.ps1` (`Get-PwGhRounds`, now shared with `board rounds`), `progress.ps1`, `packet-progress/SKILL.md`, README, tests | – (visibility) | – | unchanged: only trusted markers count | – |
| 7 | README: links this page, documents the new keys, and says MCP servers cost credits in every call. | README | 14% if they were on | – | – | – |

One more change, for safety rather than credits: review-scope now reports the panel's limits (`Settings`: `maxRounds`, `shouldFixPassFromRound`, `maxParallelLenses`, `lensesPerReviewer`) from the config at the base. The panel uses those values, so a packet branch can't relax its own panel by editing the config.

On the sandbox's real markers (written as tier 4, and priced at tier 3), `progress.ps1 -Credits` estimates PKT-1 at 1,529 credits on the default rates, against this page's 1,530. On 0.1.1's rates it was 2,858, against 2,870.

The **lean profile** adds these trade-offs, each named. They are not built:

| # | Change | Saves on top, 10-packet phase | Trade-off |
| --- | --- | --- | --- |
| 8 | A per-agent model class written by `install.ps1`, for example `"models": { "agents": { "packet-dispatcher": "standard", "packet-reviewer-deep": "standard" } }` | 0 while every class lists the same models; with a dearer strong class, the difference in the dispatcher's and tier 3's rates | Tier 3 runs on a lighter model; the dispatcher's brief and triage do too. In the Local harness, check that tier 3 reviewers still start from a standard-class dispatcher. |
| 9 | Pass `-FixedConfirmed` only when a fixed finding was blocking | 110: S packets only, since M and L start at the top tier | The tier floor no longer rises after should-fix-only fixes. |

On one model the lean profile adds about 1% to the budget profile's saving. It is worth its trade-offs only with a dearer strong class.

Results:

| | Default | Budget | Lean |
| --- | --- | --- | --- |
| S packet, typical | 1,190 | 805 | 770 |
| M packet, typical | 2,165 | 1,400 | 1,400 |
| L packet, typical | 3,425 | 2,170 | 2,170 |
| Stage 5 packet (PKT-1), as run | 1,530 | 1,035 | 1,035 |
| 10-packet phase, all in | 21,600 | 14,100 | 14,000 |
| Per packet, all in | 2,160 (US$22) | 1,410 (US$14) | 1,400 (US$14) |
| **Packets a month on 12,500** | **5.8** (3–10) | **8.9** (5–15) | **8.9** (5–15) |
| 10-packet phase, in months of 12,500 | 1.7 | 1.1 | 1.1 |

The ranges are the 0.6× to 1.75× above. Stage 5's packet keeps tier 3 under the lean profile: its `ci.yml` puts every round there.

Applied in order, the budget profile's steps save:

1. Two lenses per reviewer run: 3,500.
2. Should-fix-only rounds pass from round 2: 3,600 more.
3. Prompts name files and logs are trimmed: 450 more.

Moving CI files to the setup PR comes on top for any packet that would have owned them.

## Running it within the pool

- **Decide the kit's share.** The 12,500 credits pay for everyone's chat, CLI and agent use too. At about 1,400 credits a packet under the budget profile, giving the kit 8,000 a month means about five or six packets.
- **Prefer a cost-center budget with paid usage allowed** over a hard user budget. A user who runs out of budget loses Copilot in the middle of a run, with no fallback model. The packet's claim then lasts out its 30-minute lease, and `resume` repeats the interrupted round. Paid usage is billed at the same rate: a 10-packet phase under the budget profile is about US$140, against the US$125 included.
- **Start the costly packets early in the month.** An L packet under the budget profile is about 2,200 credits, a sixth of the pool.
- **Your own API key** keeps the kit out of the pool entirely. The end-to-end run worked this way. Check with your admin whether enterprise BYOK is allowed.
- **Keep packets M-sized and in one area.** Overhead per packet (preflight, brief, PR, hand-off) is about 175 credits. Above 1,000 lines, every round runs more lenses, each over a bigger diff, so an L packet costs about 1.6× an M one.

## Calibrate

The token shapes are the biggest guess on this page. Replace them as soon as there is data:

1. **Stage 5, already run (history).** That run used the models and the four-tier panel of its day, not GPT-6.1 Sol, so it can calibrate the token shapes (calls, context and output per run), not today's rates. In the API key's usage console, read 2026-10-19 from about 20:55 to 22:05 UTC: the brief was posted at 21:09:36Z and the hand-off at 21:59:21Z. Opus 5.5 tokens there are the dispatcher plus eight tier-4 reviewer runs (today's tier 3); Sonnet 5.5 tokens are the three implementer runs. This is accurate only if nothing else used the key in that window.
2. **The first packets on Copilot-hosted models.** Run one dispatcher a day. Then download the AI usage report from the billing settings. It totals credits by date, model and user, and since August 2026 it also shows input, output, cache-read and cache-write tokens per model ([Visual Studio Magazine](https://visualstudiomagazine.com/articles/2026/08/13/big-copilot-bills-github-now-lets-you-peek-into-per-model-token-usage.aspx), secondary). The day's totals are then one packet's cost.
3. Divide by the run counts from `board rounds <pr>` and the fix commits, and update `budget.creditsPerRun` and this page.
