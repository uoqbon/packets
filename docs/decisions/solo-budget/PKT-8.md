# PKT-8 · Decision record

Choices [PKT-8](../../plan/solo-budget/packets/PKT-8.md) left open, and why each went the way it did. Every claim in the README and cost page was checked against the code merged on `main` at `e3e16b2` (PKT-1 to PKT-7, and #42), not against the packet files.

## The README

1. **Configure rows follow the code that reads each key.**
   - `review.tierCap`: 2, 3 or `null`, read by `Get-PwConfig`, which loads `"2"` as 2 and stops on anything else, so board, progress and review-scope exit 2 on a bad value. A cap of 3 changes nothing (PKT-3, decision 1).
   - `models.agents`: read by `Get-PwAgentModelClass`, which the installer and review-scope call and board and progress never do. A bad entry stops the installer with exit 2 before it writes anything (PKT-4, decision 8). review-scope only puts the error into `ModelCheck.Warning` (PKT-3, decision 11), so the row doesn't claim review-scope stops on it.
   - `budget.maxCreditsPerPacket`: read by `Get-PwCreditCeiling`, which only `credit-check.ps1` calls, so a bad value stops the check, not board or progress. The row says every dispatch runs the check (it prints `OFF` with no ceiling), which is the plan's first "Opt-in only" exception, and that a start check that fails skips the packet rather than posting a Needs human, as the dispatch skill's Select says.
   - `budget.creditsPerRun`: GPT-6.1 Sol's rates, half of 0.1.1's for the dispatcher and tier 3 (PKT-7, decision 1). This is the amendment in #38.
2. **`-Profile solo` gets a sentence in Install,** since the solo section and the Configure rows name the profile. It says what the overlay sets and that an existing config is only compared, as PKT-4's decision 4 has it.
3. **The Use section names both first lines and the options each offers,** in the dispatch skill's order. The config-only raise follows PKT-6's decision 10d: a ceiling raised only in the config doesn't resume a stopped packet; the dispatcher waits for a `packet:budget` comment. The narrow settle lists every condition the skill's **Settle** sets: after `reason=budget next=fix`, at the newest round's head, with that round's findings open, and a comment that is the marker alone.
4. **The Models bullet keeps the cost-tier rule, then says what the kit does about it.** Three layers, each named for what it is: the installer's warning and review-scope's `ModelCheck` read the config, not the session, so they say a round *can* stop; the panel's stop is an instruction. "Run the dispatcher on a model at least as capable as packet-reviewer-deep's" is gone; the fixes the stop offers (a dearer session, the Copilot harness, `models.agents`) replace it.
5. **"The review tier is a floor" is a row of its own,** before "A packet branch can't weaken its own review", since the second leans on the first. The forced list is review-scope's `$forced` as merged (`$files -eq 0`, machinery, attributes, `max`, `deep`) plus the Review tier line, which review-scope applies after the cap. "The panel never lowers it" is described as the panel's instructions (packet-review, Limits 5), since no script checks what agent the panel runs. The previous-tier carry is review-scope's `-PreviousTier`.
6. **The amended rows say what the scripts do, and only that.** The ceiling and pricing come from `credit-check.ps1` (PKT-5, decision 3). The packet says "a credit check that exits 2 stops the dispatch"; the merged instructions go on only on exit 0, treat 3 as the stop and stop the step on any other code, 1 included (PKT-6, decision 2), so the row says that.
7. **The markers row now names the budget raise.** CONTRIBUTING asks that a change to markers updates the table. `packet:budget` is read by `credit-check.ps1` through `Get-PwGhRounds`, with the same trust rule, and only as a comment's first words (PKT-5, decision 9). The row points to the Known limitation on the dispatcher's own login.
8. **Three Known limitations, as the packet lists them.** The forged-raise line says what each forgery can do: a raise spends credits; a narrow settle can only pass reported findings; a settle after the last round could always carry a change, and the owner's review of the PR is the backstop there.
9. **The ideas list says `review.maxRounds` (3)** in both places it said three rounds.

## The cost page

10. **The solo section reuses the defaults' method** (the review notes' "Credits on GPT-6.1 Sol"): the defaults' lens counts, runs as lenses over 3 rounded up, two rounds with one fix, a 20-credit resume share on two-round packets, and the one-clean-round lens counts of the defaults' best cases (S 2, M 3, L 4). The figures are the review notes' to within 5: S 675, M 985, L 1,465 typical; 370, 535, 875 for one clean round; 820, 1,290, 1,995 forced to tier 3.
11. **"Expected" is 11% one clean round and 89% typical,** the original project's 8 of 73 one-round packets. The per-seat table uses the expected 10-packet phase over ten (975), since the plan's goal and the review notes give per-month figures on it. The default column uses the default 10-packet phase over ten (2,160).
12. **Seats.** Pro, Business and Enterprise, as the packet asks, plus Pro+ and Max for reference, from the figures the owner chose to cite (review notes, decision 9).
    - **Checked 2026-11-09 against GitHub's pages (see [Verified sources](#verified-sources)).** Pro 1,500, Pro+ 7,000, Max 20,000, Business 1,900 and Enterprise 3,900 are all right. So the seat table, the "In short" bullet, the plan-only phases, the "Included" row and the case file's numbers don't change.
    - **What changed is the paragraph under the table.** "Can change" was the packet's paraphrase, so it now quotes GitHub: the flex allotment is "a variable part of your included usage". It adds the Pro+ and Max splits, because flex is 44% of Pro+ and half of Max. It gives the exact reset, and says the individual figures don't apply to a Pro or Pro+ subscriber who stayed on an annual plan under premium requests.
    - **The promotional figures (3,000 and 7,000) are left out because they have ended.** GitHub's post gave them to "existing Copilot Business and Copilot Enterprise customers" for "June, July, and August". The docs said "June 1 – September 1, 2026", and that "after the promotional period, included usage returns to the standard amounts". GitHub removed that section on 2026-09-11 (github/docs commit `19a110200a`, "Remove expired billing content"). The table prices an ongoing month, and a sentence under it would describe an offer that no longer exists. Neither source said whether monthly or annual billing mattered, or said in so many words that the promotional amounts went into the pool.
13. **What the cap saves is stated per size, honestly for S.** A typical S packet starts at tier 2 with no cap, so the cap saves only round 2's step to tier 3 there (about 55), not the 145 a forced packet adds.
14. **The ceiling paragraph says what trips it,** priced with `Get-PwCreditEstimate` as `credit-check.ps1` prices each step: an unforced packet stays under through two rounds and a CI fix; a packet forced to tier 3 stays under through its two rounds, but a CI fix after them (a fix run plus a one-lens round at tier 3) or one or two extra lenses takes it over. The review notes' option B said only the forced, many-lens packet trips it; the correctness review found the CI-fix case. It says `credit-check.ps1` counts no resume share.
    - **The owner kept the ceilings (2026-11-08, PR #43).** A forced packet that needs a CI fix stopping at Needs human is the accepted trade for now. H-2's calibration is where to revisit S 950, M 1,500 and L 2,200: with measured rates, check how often a forced packet's CI fix passes them, and whether the ceilings or the CI-fix price should move. cost.md's ceiling paragraph says they stay until then.
15. **Copilot CLI's session limit is a backstop above the ceiling,** with what is and isn't known. Checked 2026-11-09 (see [Verified sources](#verified-sources)):
    - **Confirmed:** both commands, public preview, soft, a minimum of 30, and the SDK.
    - **Corrected, how it stops.** The page said it "stops mid-step". GitHub says a response in progress finishes and the next model call is blocked. For the kit that can still fall inside an implementer run, so the warning about the held claim stays, stated as between model calls.
    - **Corrected, subagents.** The packet and the first version of this page said this wasn't known. GitHub's changelog of 2026-07-01 says the limit tracks usage "across the entire session, including model calls, subagents, and background work like compaction", so the page now says that and cites it. It says "subagents", not custom agents, and nothing has measured it on the kit, so the page keeps that as still to be measured. It names no stage: PKT-9 is being written in parallel and owns the stage numbers. The packet file still says unknown; it wasn't edited, since it is the contract.
    - **Added, how long it lasts.** GitHub's pages disagree. The how-to says an interactive limit "applies for the entire session", and the changelog agrees. The command reference says it applies per response and "resets per user message". The page reports the disagreement and advises not relying on one interactive limit across several messages. No page settles it.
    - **Added, where it applies.** GitHub documents it for Copilot CLI and the SDK. No page says VS Code's Copilot harness honours it. VS Code's AI settings reference and agent-harness page don't mention it. The README's Known limitations line needed no change.
16. **The four properties' tier-floor bullet carries the amendment.** The lever rows that said "kit: a per-agent model class" now say `models.agents` is built, and lean change #8 is marked built (#9 is still not).

## Verified sources

Read on 2026-11-09, from a machine that could reach them (the session that built this PR couldn't):

| Facts | Page |
| --- | --- |
| Pro, Pro+ and Max: figures, splits, reset, no carry-over | [Usage-based billing for individuals](https://docs.github.com/en/copilot/concepts/billing-and-usage/individuals/billing) |
| Business and Enterprise: figures, pool, reset, no carry-over | [Usage-based billing for organizations and enterprises](https://docs.github.com/en/copilot/concepts/billing-and-usage/organizations-and-enterprises/billing). The address cost.md lists under *What a credit is* redirects here. |
| Annual Pro and Pro+ plans | [Model multipliers for annual plans (legacy)](https://docs.github.com/en/copilot/reference/copilot-billing/request-based-billing-legacy/model-multipliers-for-annual-plans) |
| Promotional figures and their end | [GitHub Copilot is moving to usage-based billing](https://github.blog/news-insights/company-news/github-copilot-is-moving-to-usage-based-billing/), and the section removed by [github/docs `19a110200a`](https://github.com/github/docs/commit/19a110200a) |
| The session limit | [Changelog, 2026-07-01](https://github.blog/changelog/2026-07-01-set-ai-credit-session-limits-in-copilot-cli-and-sdk/), [how-to](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/set-session-limit), [command reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference), [SDK session limits](https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/session-limits), [Optimizing your AI usage](https://docs.github.com/en/copilot/tutorials/optimize-ai-usage) |
| VS Code (nothing found on the limit) | [AI settings reference](https://code.visualstudio.com/docs/agents/reference/ai-settings), [Choose an agent harness](https://code.visualstudio.com/docs/agents/run/agent-harnesses) |

## Tests

17. **`tests/cases/cost-doc.tests.ps1` reads the solo section the way it reads the defaults' table.** It checks:
    - the section's JSON is `templates/packet-workflow.solo.json`, exactly, and the overlay sets no `creditsPerRun`;
    - each of the nine rows prices within 1% of `Get-PwCreditEstimate` on the default rates, with its runs (`Runs=`) and resume share, at tier 2 (or 3 for the forced rows), with runs equal to the lenses over 3 rounded up, and with parts that add up to the total within 5;
    - the expected figures, what a forced packet adds, the phase table, and each seat's packets a month and range follow from those rows;
    - the "In short" solo bullet (per packet, Pro, Business and Enterprise), the cap's savings per size, the ceiling's ratio to a typical packet, the plan-only phases a month, the CI-fix figures in the ceiling paragraph, lean change #8 and the amended tier-floor bullet;
    - the README has rows for the three keys, the `creditsPerRun` row no longer prices tier 3 at tier 4's old rate, the ceiling example is the overlay's, the Models bullet names the model-tier stop and not the old advice, the safety row and the budget stop are there, and the defaults the rows give (no cap, no ceiling, no `models.agents` entries) are `$script:Defaults`'.

    It keeps PKT-1's rules: plain variables, no `$script:` assignment, kit code only through `Invoke-CaseProbe`.

## Lens review

18. **Security and correctness, each an independent read of the diff against the merged code.** Nothing was blocking.
    - **Security** found that the README presented instructions as enforcement in three places: the credit check's calls (no hook or script runs it), the narrow settle's conditions (only the dispatcher's instructions check them, and a dispatcher that ignored them could post the settle-check itself) and the first-words rule (only `packet:budget` has it in code). It found that machinery under an ignored path only lifts the cap, that a config raise counts only where both the base and the default branch have it, and that the cap is read at the merge base alone. It also found that `trustedAuthors` now covers spending, and that the implementer signs in as the owner too. The README now says each.
    - **Correctness** recomputed every solo figure with the estimator and found them right. It found that a CI fix after two forced rounds passes each ceiling (decision 14), and five prose figures the case file didn't pin (the cap's savings, the ceiling ratio, the plan-only phases, Enterprise in "In short"); each is now asserted. Nits fixed: a comma splice, the full list of scripts a bad `tierCap` stops, and the review skill's rule is in its limits, not a Never list.

## Where the packet and the merged code differ

19. **The credit check's exit codes.** The packet's amended row says "a credit check that exits 2 stops the dispatch"; the code goes on only on 0, and any code but 0 and 3 stops the step (decision 6).
20. **No name differs.** `install.ps1 -PlanOnly`, the manifest's `mode`, `-Profile solo`, `models.agents`, `review.tierCap`, `budget.maxCreditsPerPacket`, `credit-check.ps1`, `packet:budget`, `packet:settle` and both `reason=` first lines are as merged.

## Not changed

- `VERSION`, `CHANGELOG.md` and the README's install tag (H-3). The e2e prompt and its stage numbers (PKT-9).
