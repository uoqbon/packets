# PKT-3 · Decision record

Choices [PKT-3](../../plan/solo-budget/packets/PKT-3.md) left open, and why each went the way it did. The forced list is the owner's (question 3 in [review-notes.md](../../plan/solo-budget/review-notes.md)).

## What the cap stops, and what it doesn't

With `review.tierCap` 2 at the base, review-scope stops these raises at tier 2. Each one stays in `Reasons` as `capped at 2 by review.tierCap: <reason>`:

| Raise the cap stops | Its reason in `Reasons` |
| --- | --- |
| more than 300 lines | `<n> lines > 300` |
| more than 8 files | `<n> files > 8` |
| code in two or more subsystems | `<n> subsystems touched: …` |
| a migration or schema path | `migration/schema path: …` |
| an API contract path | `API contract path: …` |
| an auth or security path | `auth/security path: …` |
| an infrastructure or CI path | `infra/CI path: …` |
| concurrency in added lines | `concurrency in added lines: …` |
| the +1 after a round's confirmed findings were fixed (`-FixedConfirmed`) | `the previous round ran at <n>, and its confirmed findings were fixed (+1)` |

These still reach tier 3 whatever the cap:

| Raise the cap doesn't stop | Why |
| --- | --- |
| review machinery (agents, skills, hooks, prompts, instructions, workflows, the kit's config, the project lens folder) | a PR that changes how PRs are judged gets the deepest look (the owner's) |
| a `review.deepPaths` match | the project's own per-path call (the owner's) |
| a `review.maxPaths` match | the same, for its critical paths (the owner's) |
| a `.gitattributes` change | attributes decide how the diff that sets the tier is counted |
| a diff of only ignored files (lock or generated files) | review-scope can't measure it, and a lockfile is supply-chain surface |
| the packet's **Review tier** line | the planner's per-packet call, approved in the plan PR and read at the base |
| the previous round's tier (`-PreviousTier`) | a later round never drops below the one before: the tier is still a floor |
| a raise the panel makes with a reason | the cap only lowers what the diff measures (packet-review §1) |

The two raises to tier 2 (a binary-looking file, read as text or as random bytes) are below the cap and unchanged. A cap of 3 changes nothing, and neither does no cap.

## The tier

1. **One limit, decided once.** review-scope measures the tier exactly as before and keeps it as `Uncapped`. It then works out `$limit`: the cap when one is set and no forced reason holds, otherwise 3. The measured tier becomes `min(limit, measured)`, and that is `Floor`. With no cap, or a cap of 3, `$limit` is 3 and no line of the old path changes. A comparison of the base's script with this one over the suite's 19 diffs (each with `tierCap` left out, `null` and 3, as text and as JSON) found the text byte-identical and the JSON identical once the three new fields are taken out.
2. **A forced reason lifts the cap for the whole diff.** When one holds, nothing is capped: the size, auth and other raises keep their plain reasons, because the tier reached 3 anyway. `Reasons` says "capped" only when the cap actually lowered the tier, so `Uncapped` differs from `Floor` exactly when some reason says capped.
3. **The forced raises are tagged where they are made.** The `$raise` helper takes `-Forced` for `deep`, `machinery`, `attributes` and `max`. Every other raise to 3 records its place in `Reasons`, so the cap can rewrite just those lines. The order of the reasons is the base's: the `deep` raise still comes right after `infra`.
4. **`Uncapped` is the measured tier only,** before the packet's line and the previous round, as `Floor` always was. So a capped diff under a **Review tier** 3 line reads Tier 3, Floor 2, Uncapped 3, and its text says `FLOOR=2 UNCAPPED=3 (review.tierCap 2)`.
5. **Later rounds.** The carry is the previous tier, never less (a tier 4 from before the merge counts as 3). Only the +1 is held to `$limit`. So under cap 2, `-PreviousTier 2 -FixedConfirmed` stays 2, `-PreviousTier 1 -FixedConfirmed` goes to 2, and `-PreviousTier 3` stays 3 with or without fixes. A forced reason in the diff lifts the limit to 3, so the +1 counts again there. When the cap stopped the +1, `Reasons` says so with `capped at 2 by review.tierCap: …`, and the plain "raised to" line leaves out the "(+1)" it can no longer claim.
6. **The text output changes only under a cap.** Its first line adds `UNCAPPED=<n> (review.tierCap <cap>)` when `Uncapped` differs from `Floor`, and the `SETTINGS=` line ends with `, tier cap <cap>` when a cap is set (3 included, so the run says which config it read). A `MODEL CHECK:` line follows only when there is a warning. With no cap and no `models.agents`, the text is byte-identical to the base's.
7. **`Settings.TierCap` is the base's value,** read through the same `Get-PwConfig -Ref <merge base>` call as every other setting, so a branch that sets `tierCap` 2 gets no cap (and tier 3: the config edit is machinery). A branch that removes the base's cap still reads 2. A `tierCap` the config check refuses (1) makes review-scope exit 2 through Get-PwConfig, as PKT-1 left it.

## ModelCheck

8. **Every round gets one,** not only tier 3. It holds the round's agent (after the `review.agents.4` rule), that agent's class and packet-dispatcher's, both from `Get-PwAgentModelClass` over the base config's `models`. With the kit's classes the dispatcher is strong, the top, so no round warns until `models.agents` moves it down.
9. **The warning's test.** The agent's class must rank above the dispatcher's (light < standard < strong), and the two classes' model lists must differ. The lists are compared in order, case-sensitively, after trimming each entry. Order counts because the first model in a list is the one the agent file pins first. With the template's identical lists, nothing warns.
10. **The text.** The warning names the agent, both classes and their model lists, and VS Code's Local harness, and says what to do: run the dispatcher's session on a model of the agent's class, or make the two lists match.
11. **Advisory, never an exit.** The check runs in its own `try`. If `Get-PwAgentModelClass` throws (a `models.agents` entry naming an unknown class or an agent the kit doesn't ship), the message goes into `Warning`, and the classes stay null. An agent the kit doesn't ship (a project's own reviewer) has a null class and no warning, because the kit doesn't know its model.
12. **The panel tells the owner before the first pair** and then carries on, unless the owner says otherwise. Stopping on a refused reviewer is PKT-6.

## Skills

13. **packet-review.** §1 lists the new fields and adds two paragraphs: one on the cap and its exceptions, one on the model check. Limits item 5 names the cap and the forced list. The reviewer prompt's tier line adds `, capped from <uncapped>` when `Uncapped` differs from `Floor`, which gives, for example, `tier 2 standard (floor 2, capped from 3)`. The round report's Tier field adds `(capped from <uncapped> by review.tierCap)` in the same case. The skill's front-matter description still says "at most three rounds": the packet doesn't list it, and the review notes give "three rounds" in the text to PKT-6 and PKT-8.
14. **packet-plan.** A new rule, "Review tier under a cap", tells the planner to give a packet that changes auth, a migration or schema, a contract later packets consume, or concurrency a `- **Review tier:** 3` line, and to say why in its Dispatcher notes. The size rule says `review.maxRounds` rounds instead of three.

## Where the packet and the merged code differ

15. **No names differ.** The packet's `Get-PwAgentModelClass`, `review.tierCap` (`$null`, 2 or 3 from `Get-PwConfig`) and the case-file helpers are as PKT-1 merged them. The packet calls the forced reason for lock and generated files "only ignored files changed", which is review-scope's own `$files -eq 0` case.

## Tests

16. **`tests/cases/tier-cap.tests.ps1`** runs review-scope in a New-CaseRepo repository, with configs written per case (`-ConfigPath`). The only exception is the base-config checks, which commit `tierCap` on a branch and read it at the base. For each of seven diffs it checks that `tierCap` left out, `null` and 3 give the same `Tier`, `Floor`, `Agent`, `Reasons`, `Lenses`, `Runs`, `Pairs` and existing `Settings`, that `Uncapped` equals `Floor`, and that the only new fields are `Uncapped`, `Settings.TierCap` and `ModelCheck`. It doesn't run the base's script; that comparison is decision 1's, done once by hand and reported in the PR. The suite's own review-scope tests run on the template's `null` and still pass unchanged.

## Not changed

- The README's safety-model table (PKT-8). Its review-tier row still holds under a cap: kit, agent, hook and project-lens paths are forced, so they still raise the review to tier 3.
- `VERSION`, `CHANGELOG.md`, the solo template (PKT-4) and the credit check (PKT-5, PKT-6).
