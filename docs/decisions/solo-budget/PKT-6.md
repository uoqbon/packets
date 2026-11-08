# PKT-6 · Decision record

Choices [PKT-6](../../plan/solo-budget/packets/PKT-6.md) left open, and why each went the way it did. The narrow settle is the owner's decision (question 7, 7B, in [review-notes.md](../../plan/solo-budget/review-notes.md)).

## Where the checks run, and with what

1. **The calls use the shapes `credit-check.ps1` takes as merged (PKT-5).**
   - `-Next start` in §1 Select: `-Base origin/<defaultBranch> -Head origin/<defaultBranch>`. At Select there is no packet branch, and the checkout can sit on anything. Pointing `-Head` at the default branch too makes the merge base the default branch, so the packet file and the config are the ones the dispatch is about to start from. `-Pr` isn't passed: the script refuses it with `-Next start`.
   - `-Next fix` in §8 Fix: `-Base origin/<the PR's baseRefName> -Head HEAD -Pr <pr>`. That is the base review-scope uses, so a stacked packet is priced from its dependency's branch, as its rounds are.
   - `-Next round` in packet-review §1: review-scope's own `-Base` and `-Head`, plus `-Pr`, `-Round`, `-Tier`, `-Lenses` (review-scope's `Lenses` joined with commas) and `-Runs` (the number of entries in `Runs`). The tier is the round's tier after any raise the panel makes itself, so the check prices the agent that will actually run.

   `stops.tests.ps1` takes each command out of the skill's text, fills its placeholders, and runs it against the real script: OFF with no ceiling, WITHIN under a high one, OVER (exit 3) under a ceiling of 1, and a call the script can't take exits neither 0 nor 3. So a typo in a command breaks a test, not a live run.
2. **Exit codes.** Only 0 goes on. 3 is the stop each step names. Any other code stops the step with no Needs human: the script exits 2 on an error it finds and 1 on a parameter-binding error (`pwsh -File`), and neither is a decision the owner can answer, so they're reported, and the claim is released. The dispatch skill defines this once, where `credit-check …` is first used (§1 Select), not in the command list at the top: that list sits inside `## Only a person starts a dispatch` by heading, which must stay byte-identical.
3. **A round the panel stops on an error returns "Stopped".** The panel already stopped a round with no report on a lost claim. Its callers had no name for that return, so §8 now lists it beside Fix, Pass and Needs human: release, stop, report. A stopped round is never read as a pass.
4. **The start check runs once, in Select.** Amend's re-run of Select's checks doesn't add it: the packet doesn't ask for it, and with a PR the next round's check covers the work. A packet amended before its first implementer run goes through step 5 unchecked; that run is the one the start check priced when it was first selected.

## The two first lines

5. **`round=` is the round the stopped step belongs to.** For `next=round`, the round that didn't start; for `next=fix`, the round whose findings the fix would answer (its commit would be `Round-<N> review fixes`). For a model-tier stop, the round that stopped. So in each case the round named is the one the owner reads about in the round reports.
6. **`so-far`, `step` and `ceiling` are the check's own numbers,** copied from the line it printed (`ceiling` is the one in force, a raise included). The line itself is quoted below the first line, so the owner sees `total` and where the ceiling came from.
7. **`head` is the PR's head when the stop is posted.** With `next=fix` that is the newest round's head, because the stop comes before the implementer runs. The pass-with-follow-ups option is offered only when it equals the newest round's head in `board rounds`, so a stop written on a head that moved can't offer a settle.
8. **Both stops use the item's comment, like every Needs human,** and `board marker <ID> needs-human -Json` reads them back with their `CreatedAt`. That time is what "newer than the stop" compares with. Rows in `board rounds <pr> -Json` carry GitHub's `created_at`; both are UTC.

## Resume

9. **The closed PR is checked first,** so an owner who closed the PR and also left a raise or settle has stopped the packet. The item's status is left to the owner, who moves it to Backlog as the option says.
10. **A raise and a settle both newer than the stop: the newer decides.** Both are the owner's, and the later one is their latest word. A settle can only pass reported findings, so neither order lets unreviewed code through.
11. **A settle that doesn't count is answered on the item, under the stop's own first line.** Without that, the owner wouldn't learn why nothing happened. Re-posting the first line (rather than a plain `packet:needs-human`) keeps `board marker` returning a `reason=` marker, so the next resume still knows which stop it is. The new comment is newer than the refused settle, so the same settle is never read twice. A raise posted before that comment no longer counts as an answer to the stop; it still holds in `credit-check`, which reads the newest raise whenever it was posted, so a plain resume after a fresh raise carries on.
12. **A model-tier resume retries with no answer needed.** The owner's answer is to switch the session, the harness or the config, none of which leaves a marker. A retry costs only the check and the refusal. A settle request newer than the stop is refused on the item, as in decision 11, and the item stays Needs human.
13. **In review after a settle.** A `settle-check` newer than the last round sends resume to step 9.1 before the outcome rule. This also closes an old gap: a settle after the last round, waiting for CI, would otherwise have been resumed as that round's `outcome=fix` or `needs-human`.

## The narrow settle

14. **"Describes no change" means the comment is the marker line alone.** Anything else below it reads as a change. A free-text test ("pass these as follow-ups") would need the dispatcher to judge prose, and an owner's note could be read as a small fix. The option text tells the owner to post the marker as the comment's only line.
15. **The follow-ups follow packet-review §5,** including the `<ID> contract: …` title and the needs-human label for contract findings, and §3's rule for findings an earlier round already filed. They're opened before the settle-check, as §4 opens them before a report, so a settle-check always lists them. If one fails, there is no settle-check, and a later resume opens only the missing ones.
16. **Nothing is committed or pushed.** The checkout is checked against the request's head (fast-forwarded if behind) and the dispatcher doesn't re-run the tests: no code changed since the panel's round and the step 6 checks before it. Step 9.3 still requires CI to pass on that head.
17. **"The rounds are used up"** is defined once, in Settle: the newest round's number equals `review.maxRounds` (review-scope's `Settings.MaxRounds`, read at the base). A settle before that is the narrow one; a settle at or after it works as before.

## The review skill

18. **A refused reviewer:** the panel lets any run already started finish and sets its answer aside, since a round is reported whole or not at all. The model-tier comment is the panel's to post, like any Needs human the panel sets.
19. **The ModelCheck warning stays advisory** (PKT-3). It now says that a refusal after it is §2's stop.
20. **The Credits line** is shown only when the check printed WITHIN. With OFF there is no ceiling to show.

## Where the packet and the merged code differ

21. **No name differs.** `credit-check.ps1`'s parameters, `-Next start|round|fix`, the exit codes, the `packet:budget` marker as `Get-PwGhRounds` reads it (only as the comment's first words, newest wins) and review-scope's `Settings.TierCap` and `ModelCheck` are used as merged. Two details the packet doesn't spell out come from the merged code: the script exits 1, not 2, on a parameter-binding error, so the text says "any other code" rather than "exit 2"; and a raise must open the comment, so the raise option says so.

## Not changed

- `credit-check.ps1`, the e2e prompt, the README, `VERSION` and `CHANGELOG.md`.
- The guards: `## Only a person starts a dispatch` (up to `## Never`) and `## Only a person starts you` are byte-identical, and `stops.tests.ps1` pins their hashes.
