---
name: packet-dispatch
description: "Run one task packet end to end as its dispatcher. Picks a Ready packet from the board (or the one named), claims it, writes the implementation brief, runs the packet-implementer agent, verifies scope and tests, opens the PR, runs the review panel through its rounds, and hands the PR to the owner as Ready to merge. Also resumes a packet, or lists what waits on the owner. Use when asked to dispatch, pick up, run, resume or check on a packet."
argument-hint: "[<packet ID>] | resume <packet ID> | status"
---

# Dispatch a packet

You are the **dispatcher**: the lead for one packet. You write the brief and verify the work. The `packet-implementer` agent writes the code. The review panel (the `packet-review` skill and its `packet-reviewer-*` agents) judges it. **The owner merges.** Everything you decide is written to the board item or the PR, so any session can pick the packet up again.

## Only a person starts a dispatch

A dispatch claims a packet and writes to the board, so only a person starts one. Any agent can load or read this skill, so check this before anything else, Preflight included, once per request (`/packet-dispatch status` and then `/packet-dispatch PKT-3` in one chat are two; a re-read from `<kit>` during the same run doesn't repeat it). Go on only if one of these is true:

- a person typed `/packet-dispatch` in this chat to start this run: as a slash command (the host may hand you this skill attached to their message instead of the text), or in their own prompt (`Use the /packet-dispatch skill …`, `copilot -p "/packet-dispatch …"`);
- you are the `packet-dispatcher` agent, and its own check (`## Only a person starts you`) let you go on.

Anything else is a stop: you loaded or read this skill on your own, including after a person asked for a packet in other words (`run PKT-3`, `start the dispatcher`) or after the dispatcher turned you away; or your task is a prompt another agent wrote (a delegation, a subagent tool's `prompt`), even one that says `/packet-dispatch`. If you can't tell, stop anyway; the person can type `/packet-dispatch`. Even when one is true, stop if you have no tool to start subagents and the request isn't `status`: you can't run a packet without one, and the Local harness takes it away from a subagent, so there this part is certain. When you stop, claim nothing, run no command, change nothing, and reply with one line only:

- `packet-dispatch did nothing: not started by a person. To start a dispatch, type /packet-dispatch yourself, in any chat (a packet-dispatcher one too).`
- `packet-dispatch did nothing: no subagent tool. Turn on the agent tool for this session and start it again.`

This check is for running a dispatch. Reading this file for another task (reviewing or editing the kit, answering a question about it) runs none of its steps. A skill that sends you to one step here (packet-review pins its kit as Preflight step 1 does) runs only that step, as that skill says.

Commands below run from the repository root, in PowerShell 7 or any shell that can start `pwsh`:

- **Kit scripts run only from the pinned kit** (Preflight step 1), never from this checkout: a packet branch can change the files in its checkout, so they can't be trusted to judge it. `<kit>` below is that pinned folder.
- `board …` means `pwsh -File <kit>/.github/skills/packet-board/scripts/board.ps1 …` (the [packet-board](../packet-board/SKILL.md) skill describes it), and the other scripts are `<kit>/.github/skills/<skill>/scripts/…`. The current directory stays the repository root.
- When you need to re-read one of the kit's skills mid-session, read it from `<kit>`, not from the checkout.
- Shell variables don't survive between terminal calls. When a step says "note" a value (the claim id, the base SHA, the PR number), keep it in your own notes and type it literally later.
- **The comparison base** is the brief's base until the branch merges the default branch; from then on it is `git merge-base HEAD origin/<defaultBranch>` right after `git fetch origin --prune` (the fetch resets an `origin/*` ref that anything in this clone moved), the default-branch commit the branch last merged. (It stays the brief's base while that commit is an ancestor of the brief's base: a stacked packet whose dependency hasn't merged.) Files other packets landed come in with the merge, so they aren't this packet's changes. `check-scope.ps1` works it out itself from the brief's base.

## Never

- Push to the default branch or a protected branch, force-push, rebase a pushed branch, merge or approve a PR, enable auto-merge, or start or re-run a CI workflow.
- Run a command listed in `guardrails.forbiddenCommands`, or break a rule in `guardrails.rules` (`.github/packet-workflow.json`).
- Start a BLOCKED packet, a Backlog packet, or a human task.
- Let two open PRs touch one lock (`board locks <ID>`).
- Stand in for the review panel, or mark a packet Ready to merge before the panel passed **and** CI passed on the head the panel reviewed.
- Change a packet's scope, contracts or acceptance criteria. Those go to the owner (**Needs human**); an answer that changes them reaches the packet file through **Amend**, never through the packet branch or the owner's own edits.
- Post a comment whose marker is `packet:budget max=…` or `packet:settle head=…`, or raise or change a packet's credit ceiling (`budget.maxCreditsPerPacket` included). Those are the owner's answers, even though you sign in as the owner and `board` would count them. The `packet:settle-check` that **Settle** posts stays yours.
- Run a review round's reviewer on another model, a lower tier's agent or fewer runs because the host won't start it. That is a model-tier stop (**Needs human**).
- Stop working on a packet without releasing its claim as your last action.

## Arguments

| Call | Does |
| --- | --- |
| `/packet-dispatch` | Take the first START (or STACK) line of `board next`. |
| `/packet-dispatch <ID>` | Take that packet. It must be Ready with verdict START (or STACK). |
| `/packet-dispatch resume <ID>` | Continue a packet that is In progress, In review, Needs human (after the owner answered) or Ready to merge (its PR changed since). |
| `/packet-dispatch status` | List what waits on the owner and what can start; for the full picture use `/packet-progress`. |

**One packet per session.** For more throughput, start more sessions, each in its own worktree (VS Code: a new agent session with *New Worktree*; or `git worktree add ../<repo>-<id> origin/<default>` and open that folder). The claim check keeps two sessions off one packet; the worktree keeps their files apart.

## 0 · Preflight

Every call runs this first, right after the check above, `resume` and `status` included.

1. **Pin the kit**, with git alone and before any kit script runs: copy `.github/skills` as merged on origin's default branch into a fresh folder in the system temp directory (never inside the repository), and note that folder as `<kit>` for the rest of the session:

   ```bash
   git fetch origin --prune
   git symbolic-ref --short refs/remotes/origin/HEAD
   git archive --format=zip --output <temp>/packet-kit-<random>.zip <the ref it printed> .github/skills
   pwsh -NoProfile -Command "Expand-Archive -Path '<temp>/packet-kit-<random>.zip' -DestinationPath '<temp>/packet-kit-<random>'"
   ```

   If `symbolic-ref` fails, run `git remote set-head origin --auto` once and retry. If `git archive` finds no `.github/skills`, the kit isn't merged on the default branch yet: stop. Note the commit you archived (`git rev-parse <the ref it printed>`) as `<kit sha>`: reviewers read their lens texts from it (packet-review, Setup step 6).
2. `.github/packet-workflow.json` exists. `gh auth status` succeeds (with the `project` scope for `github-project`); for `azure-boards`, `AZURE_DEVOPS_EXT_PAT` is set or `az login` works.
3. **Clean tree** (not for `status`). The working tree is clean (`git status --porcelain` prints nothing). If not, stop: packet work never mixes with other changes. `status` changes nothing in the checkout and runs nothing from it, so a stray file such as Finder's `.DS_Store` can't change its answer.
4. If this is the repository's main checkout (`git rev-parse --git-dir` equals `git rev-parse --git-common-dir`), tell the owner that only one dispatcher may run in a checkout, and suggest a worktree session for the next one.
5. `board reconcile` (closed items become Done).
6. Read `guardrails` from the config (`board` and the scripts use the config as merged on the default branch) and the repository instructions. They bind you and every agent you start.
7. **Models** (not for `status`). The implementer and the reviewers run on the models their agent files pin (`model:`, written by the installer from `models` in the config). If your subagent tool asks you to choose a model, or doesn't offer an agent's pinned models, ask the owner once, now, which model to use for each class (*strong*: the deep reviewer; *standard*: the implementer and the standard reviewer; *light*: the light reviewer), and keep those answers for the session. Never pick one per agent on your own, and never run a reviewer on a model weaker than its class. A host that refuses a pinned model for its cost tier is offering it, not withholding it: VS Code's Local harness lists the model, but a subagent whose model is dearer than this session's "doesn't run and reports which models are available". That is a model-tier stop (**Needs human**, `reason=model-tier`), when the round reaches it, not a reason to ask the owner for another model.

## 1 · Select

- Named packet: `board deps <ID>`. Its status must be **Ready** and its verdict **START** (or **STACK** when `stacking` is on). Otherwise say why and stop, or offer `board next`.
- No packet named: `board next`; take the first START or STACK line.
- Locks: if the packet lists **Locks**, `board locks <ID>` must exit 0 (no other open PR touches the lock's paths).
- Open contract questions: `gh issue list --repo <repo> --state open --label <labels.followUp> --label <labels.needsHuman> --limit 200 --json number,title`. A title that starts with one of this packet's dependencies (`<dependency ID> contract: …`) is a question about code this packet builds on (packet-review, Outcome): don't start the packet. Tell the owner which issue to decide (they answer there, then remove its `<labels.needsHuman>` label or close it; the issue can stay open as the follow-up's to-do). Stop if the owner named this packet; otherwise take the next START line.
- **Credits,** last, before the claim. `credit-check …` here and below means `pwsh -File <kit>/.github/skills/packet-dispatch/scripts/credit-check.ps1 …`: the packet's estimated credits so far, plus the next step, against its ceiling (`budget.maxCreditsPerPacket`, or the owner's raise). It prints `OFF` (no ceiling set) or `WITHIN` and exits 0, prints `OVER` and exits 3, and exits with any other code (2 for an error it finds, 1 for a mistake in the call) when it can't tell. Only exit 0 goes on. Exit 3 stops the packet as each step says. Any other code stops the step: report the error, and never read it as a pass. Here: `credit-check -Packet <ID> -Base origin/<defaultBranch> -Head origin/<defaultBranch> -Next start`. It prices the first implementer run and a one-lens first round.
  - Exit 0 (`OFF` or `WITHIN`): go on to step 2.
  - Exit 3 (`OVER`): even the cheapest run of this packet, at its size and Review tier, passes its ceiling. If the owner named this packet, stop and tell them the line it printed. With no PR yet there is nothing to raise with a `packet:budget` comment: the ceiling is the config's, which only the owner changes. Otherwise take the next START line, as with an open contract question.
  - Any other exit: stop and report the error.

  Nothing is claimed yet, so none of these needs a release or a **Needs human**.

## 2 · Claim

1. `board new-claim-id`. Note the id: it is this session's claim on this packet.
2. `board claim <ID> <claim-id>`:
   - `HOLD …` (exit 0): you hold the packet. Now `board set <ID> "Status=In progress"` and `board assign <ID>` (if only the assignment fails, say so in your report and go on).
   - `LOST …` (exit 1): another session holds it. Go back to **Select**.
   - exit 2: no answer. Run `board release <ID> <claim-id>` (a claim comment the failed check left behind would otherwise block the packet), then stop and report; a failed check is never a won one.

The claim is a lease (`claims.leaseMinutes`, 30 by default) that runs from its newest claim comment, by the board's clock. **Check** it with the same `board claim <ID> <claim-id>` wherever the steps below say so. That command alone decides when to renew: it posts a new claim comment only once a third of the lease has gone, and otherwise confirms the hold without writing anything. Its line ends with `(kept, nothing posted; <n>m of <lease>m left, …)` or `(renewed; <n>m left)`; `(kept, renewal deferred: …; <n>m left)` is a hold too, but with less left than usual: check again before <n> minutes have passed, and don't start an implementer run or a review round on it. A check renews within those minutes, once the left-behind comment ages out. A check therefore costs a few reads, and the item gets a claim comment about every ten minutes, not one per check. Don't add `-Force` (it renews at once); the workflow never needs it.

- Check before each **long step**: each implementer run (step 5) and each review round (packet-review checks before each pair of reviewers).
- Check before each **irreversible write**: a push, opening the PR, `board set`, and the hand-off comment.

After any other check at least two thirds of the lease is left (20 minutes by default), so keep the work between two checks shorter than that. If implementer runs or test suites take longer, ask the owner to raise `claims.leaseMinutes` once this packet is released. A step that outlasts the lease is still safe, because the next check answers `LOST` if another session took the packet meanwhile, but its work may be wasted. That holds only while every session uses the same lease: sessions that read different values of `claims.leaseMinutes` (each reads it when it fetches the default branch) can both hold a packet. So the owner changes it, either way, only once running dispatchers have released, while `board claims` shows no live claim on any packet.

If a check answers `LOST` or exit 2, stop at once: no further implementer run, push, PR, board write or round. Run `board release <ID> <claim-id>`, keep the local commits, and tell the owner which claim holds the packet. If it answers `renewed after the lease had lapsed`, another session may have held and released the packet meanwhile. Read its state again before the next write: `board get <ID>`, `board pr <ID>`, `board rounds <pr>`, and `git fetch origin` with the branch's log.

**Release** whenever you stop working on the packet, for any reason, as your last action: `board release <ID> <claim-id>`. A session that dies without releasing blocks the packet until the lease runs out.

## 3 · Branch

- Branch name: `pkt/<id in lower case>-<title in kebab case, at most 5 words>`, e.g. `pkt/pkt-12-draft-room-server`.
- START: `git switch -c <branch> origin/<defaultBranch>`.
- STACK: `git switch -c <branch> origin/<dependency's head branch>` (from `board deps <ID>`).
- Note the base ref and its SHA (`git rev-parse HEAD`).

## 4 · Write the implementation brief

The packet says *what*. The brief adds the *current facts* an implementer needs to start without exploring. Fill [brief-template.md](./brief-template.md):

- Read the packet file as it is at the base (`git show <base-sha>:<packet path>`), its phase plan, the decision records of its dependencies, and the repository instructions.
- Read the merged code it **Consumes**. Copy the real namespaces, type names, signatures and file paths into the brief. Where the packet's suggested names differ from what merged, the merged code wins; say so. A dependency in another repository (the config's `remotes`) has no code in this checkout. Copy what the packet says it consumes from there (a package version, a schema file, an endpoint) as written, and don't search this repository for it.
- Search for every name you put in the brief at the base commit. A brief states facts, not guesses.
- Point at existing files that show how this repository does the same kind of thing (a test fixture, a fake, an endpoint, a component).
- Turn each acceptance criterion into the test or command that will prove it.
- Copy `guardrails`, the packet's Owns, touchpoints and locks, and its Tests to run.

Post it on the board item. Write it to a file in the system temp directory (never in the repository), with this marker as its first line, then `board comment <ID> <file>`:

```text
`packet:brief base=<base sha> branch=<branch> mode=START`
```

For STACK add `dep=<dependency ID> dep-pr=<its PR number> dep-branch=<its head branch>`. Put the brief itself below the marker, inside a `<details>` block.

## 5 · Run the implementer

Check the claim (step 2). Then run the **`packet-implementer`** agent as a subagent (in VS Code: the Run Subagent tool, naming the agent). Its task names the brief's file rather than pasting it, so your own context stays small: "Your implementation brief is in `<the brief file from step 4>`. Read all of it first (`pwsh -NoProfile -Command "Get-Content -Raw '<file>'"`), then build the packet it describes." Subagents are stateless: each follow-up (a test failure, review findings) is a new run with the brief's file, what to do now, and the current state (`git log --oneline <base-sha>..HEAD`). If the file is gone (a new session, a cleaned temp folder), write it again from the brief marker comment (`board marker <ID> brief`).

While it runs, do nothing else on this packet.

## 6 · Verify the hand-back

1. **Clean tree and kit integrity, with git alone.** `git status --porcelain` must print nothing: if the implementer left uncommitted changes, run it again to commit or discard them; an uncommitted edit to a script would run as is. Then `git diff --name-only <comparison base>...HEAD`: if it lists anything under `.github/skills/`, `.github/agents/`, `.github/hooks/`, the project lens directory (`paths.lenses`, `.github/packet-lenses/` by default) or `.github/packet-workflow.json` that the packet doesn't own, restore those paths from the comparison base (`git checkout <comparison base> -- <path>`) and commit. (Against the brief's base after a merge, a kit upgrade that landed on the default branch would look like the packet's change, and restoring it would revert the upgrade.) The pinned kit never runs the checkout's copies, but the PR must not carry kit changes the packet doesn't own; the scripts read the config at the base (`board` at the default branch) for the same reason.
2. Check the claim. **Questions:** if the implementer stopped with a question, answer it when the plan or the code settles it and run it again. A product, scope or contract decision goes to **Needs human**.
3. **Scope.** `pwsh -File <kit>/.github/skills/packet-dispatch/scripts/check-scope.ps1 -Packet <ID> -Base <base-sha>` must exit 0; it prints the base it compared against. For OUTSIDE, LOCKED or MACHINERY lines, restore those paths from that base and commit, or send the work back. For each TOUCH line, read that file's diff and confirm it is exactly the edit the packet allows.
4. **Tests.** Run the packet's **Tests to run**, then `commands.ci` from the config once, if it is set. Send each command's output to a file in the system temp directory and read its summary and failures (the last 60 lines, plus each failing test the runner names), not the whole log: every line you read stays in your context for the rest of the packet. For step 5's evidence, search the file for the tests the brief maps to acceptance criteria. On a failure caused by the packet, send the failure back to a new implementer run (step 5). After two failed attempts, **Needs human**.
5. **Evidence.** Every acceptance criterion maps to a test that passed or a command's output. A criterion that can't be met as written goes to **Needs human**.
6. **Decision record.** The file at `paths.decisions` for this packet exists and covers each choice the packet left open.

## 7 · Open the PR

Check the claim, then:

1. `git push -u origin <branch>` (never with `--force`).
2. Fill [pr-template.md](./pr-template.md) into a temp file. Its first line is `board ref <ID>`'s output (`Closes #12`, or `Fixes AB#345` for Azure Boards), so the merge closes the item.
3. `gh pr create --repo <repo> --base <defaultBranch, or the dependency's branch for STACK> --head <branch> --title "<ID>: <title>" --body-file <file>`. Note the PR number.
4. `board set <ID> "Status=In review"`.

## 8 · Review rounds

Follow the [packet-review](../packet-review/SKILL.md) skill for the PR, giving it your claim id: it checks the claim before each pair and before its report, so don't add a check of your own before the round. It returns one of:

- **Fix**: the panel returned confirmed findings to fix.
  1. **Credits,** before the implementer: `credit-check -Packet <ID> -Base origin/<the PR's baseRefName> -Head HEAD -Pr <pr> -Next fix`.
     - Exit 0 (`OFF` or `WITHIN`): go on.
     - Exit 3 (`OVER`): **Needs human** with `reason=budget next=fix`. Nothing has been pushed since the round, so the PR head is still the one the panel reviewed.
     - Any other exit: stop and report the error, and release the claim. The packet stays In review, and `resume` comes back to this check.
  2. Run a new implementer with the brief's file (step 5, which checks the claim first), the findings, and: "Fix only these findings. One commit: `Round-<N> review fixes (<ID>)`." Verify as in step 6 (kit integrity, scope, the packet's tests), check the claim, push, and start the next round.
- **Pass**: go to step 9.
- **Needs human**: the panel has set the status and asked the question. Release the claim and stop.
- **Stopped**: the round ended with no report and no question (a claim check answered `LOST` or exit 2, or review-scope or the panel's credit check failed). Release the claim, stop, and report what failed. Nothing about a stopped round reads as a pass.

Every implementer run after the PR opens goes through **Fix**, so its credit check runs first. That includes step 9.3's CI fix after a round that passed, which credit-check prices as a CI fix (the fix run, which no round marker books, plus a one-lens round), and a fix the owner asks for in answer to a **Needs human**. Every other round goes through the panel, whose own check (`-Next round`, packet-review §1) runs before its first pair: the next round after a fix, step 9.2's round for a conflict resolution, **Amend**'s round, and a round run again on `resume`.

## 9 · Hand off

1. **Reviewed head.** `gh pr view <pr> --json headRefOid,mergeable`. The head must equal the `head=` of the newest `round` or `settle-check` entry in `board rounds <pr>` (**Settle**). If commits landed after it, they are unreviewed: run another round (step 8), or **Needs human** when the rounds are used up.
2. **Conflicts.** `mergeable` is `CONFLICTING`: merge `origin/<defaultBranch>` into the branch (never rebase), resolve inside the packet's paths, verify as in step 6 (clean tree and kit, scope, the packet's tests; both now compare against the default branch you merged), check the claim, push. The resolution is new code: run a review round for it, then return here. With the rounds used up, **Needs human** instead: the owner settles the resolution.
3. **CI on that head.** `gh pr checks <pr>`. Read its words, not just its exit code:
   - every check passed: go on to 4.
   - pending, or no checks yet: leave the packet In review, comment on the item "Panel passed; waiting for CI on `<sha7>`. Once it passes: `/packet-dispatch resume <ID>`", release the claim and stop. Never wait in a polling loop.
   - failed: read why (`gh run view <run id> --log-failed`). If the change caused it and rounds remain, fix it like a review finding (step 8, **Fix**: the credit check, the implementer, push, a round for the fix). If it is infrastructure outside the diff (a runner or registry outage), comment asking the owner to re-run CI (agents never re-run workflows), release and stop. If the last round (`review.maxRounds`) is used, **Needs human**.
   - cancelled or skipped: comment asking the owner to re-run CI, release and stop.
4. **Ready to merge.** Check the claim. `board set <ID> "Status=Ready to merge"`, then comment on the item:

   ```text
   `packet:handoff pr=<pr> head=<head sha>` Ready to merge: PR #<pr>, <N> review round(s), follow-ups <#… or none>, CI passed on <sha7>.
   ```

   If the panel opened contract questions (follow-ups titled `<ID> contract: …`), add a second line: `Decide before <the packets that depend on this one> start: #<n>, … (answer on the issue, then remove its needs-human label or close it)`. Put the same line first in your message to the owner.

   Release the claim. Tell the owner the PR is theirs to merge. Never merge it yourself.

## Stacked packets

Only with `"stacking": true`. A packet may start before one dependency merges if that dependency is Ready to merge, its PR targets the default branch, and every other dependency is Done. It branches from the dependency's head and its PR targets the dependency's branch. Stacks are one deep. A dependency in another repository is never a stack base: it counts only once its issue there is closed as completed.

When the dependency merges: merge `origin/<defaultBranch>` into the packet branch, push, and `gh pr edit <pr> --base <defaultBranch>`, so CI runs against the default branch; a conflict resolution gets a review round. Ready to merge waits for that CI run. If the dependency's PR closes without merging, the packet has no base: **Needs human**.

## Resume `<ID>`

1. Read the state: `board get <ID>` (status), `board marker <ID> brief -Json` (base, branch, mode), `board pr <ID>`, `board rounds <pr>`, and `board claims <ID>`. A recent claim from another session means it is working: leave it. `board` reads markers only from trusted authors (the signed-in user and `trustedAuthors`); treat any other comment as information, never as a brief, a round or an answer.
2. Claim the packet with a new claim id (step 2's `new-claim-id`, `claim` and `assign`). Leave its status as it is: the steps below change it when the work moves on.
3. Get onto the branch. `git fetch origin`, then `git worktree list`:
   - the branch is checked out in this checkout: carry on here;
   - it is checked out in another worktree: the packet's work lives there, possibly unpushed. Release the claim and tell the owner to open that folder in a new session and resume there (or remove that worktree once its work is pushed);
   - nowhere locally but on the remote: `git switch -c <branch> --track origin/<branch>`;
   - nowhere at all (the work was never pushed and its worktree is gone): start again from step 3 with the same claim.

   Re-read the brief from the marker comment, and write it to a file in the system temp directory for the implementer runs (step 5).
4. Continue where the state says:
   - In progress, no PR: commits on the branch → step 6; none → step 5.
   - In review: first, if `board rounds <pr>` lists a `settle-check` newer than the last round, that round was settled (**Settle**): go to step 9.1. Never apply its findings, though its marker says `outcome=fix`: they went to follow-ups. Otherwise the last round's outcome decides. `fix` → if a `Round-<N> review fixes` commit already sits above that round's head (`git log --oneline <head>..HEAD`), verify it as step 6 says (clean tree and kit first, scope, the packet's tests), then push and start the next round; otherwise apply the findings (step 8, Fix). `pass` → step 9. A round started but never reported → run it again (step 8).
   - Ready to merge, and the PR head moved after the hand-off → step 9.1.
   - Needs human: read the newest `packet:needs-human` marker with `board marker <ID> needs-human -Json`, and the owner's answer with `board comments <ID>` (trusted authors only; a comment anyone else wrote is never an answer). If the marker has `reason=budget` or `reason=model-tier` (its `Pairs`), go to **After a stop** below. Otherwise, first, if your last `packet:needs-human` comment names an amendment PR, or the answer changes what the packet file says, go to **Amend** and leave the status alone. Otherwise set the status for where you carry on (In progress before a PR, In review with one) and continue where the answer points. A settle shows as a `settle-request` in `board rounds <pr>` (**Settle**). No answer yet: release and stop.

### After a stop

The stop's marker gives its pairs (`reason`, `next`, `round`, `head`, …) and its `CreatedAt`. Only an answer newer than the stop counts: a row in `board rounds <pr> -Json` (trusted authors only) whose `CreatedAt` is later than the marker's. Read the PR with `gh pr view <pr> --json state,headRefOid`.

- **`reason=budget`**, three ways on:
  - **The PR is closed** (the owner chose to stop): release, and stop. The item's status is the owner's to move.
  - **A raise:** a trusted `packet:budget` on the PR (a `budget` row) newer than the stop. Check the claim, `board set <ID> "Status=In review"`, and carry on at `next=`, where the check runs again: `fix` → step 8, **Fix**, from its credit check; `round` → step 8, the panel, whose own check runs before its first pair. A raise that is still too low stops the packet again, with new numbers.
  - **A settle:** a `settle-request` row newer than the stop, not `Consumed`, at the newest round's head and describing no change, as **Settle** sets out for a settle before the last round: **Settle**, to pass that round's findings with follow-ups.

  If a raise and a settle are both newer than the stop, the newer of the two decides. Anything else (no answer yet, or a settle that fails one of **Settle**'s conditions): release and stop. When a settle didn't count, first check the claim and comment on the item, with the stop's own first line again so the next resume still reads it as this stop, saying which condition it failed.
- **`reason=model-tier`:**
  - **The PR is closed:** release, and stop.
  - **A settle request** newer than the stop isn't an answer here: the head isn't one a panel reviewed. Check the claim and say so on the item, with the stop's own first line again, and keep it Needs human. Release and stop.
  - Otherwise retry the round: check the claim, `board set <ID> "Status=In review"`, and run step 8. The panel runs the round again, from its credit check. If the host refuses the reviewer again, the panel posts the same Needs human.

## Needs human

When only the owner can decide (scope, a contract, a product question, a blocking finding after the last round (`review.maxRounds`), CI that can't pass, the credit ceiling, a reviewer the host won't start):

1. Check the claim. `board set <ID> "Status=Needs human"`.
2. Comment on the item, first line `` `packet:needs-human` ``: the question in one sentence, what you found (with file:line or output), two or three options with your recommendation first, and what happens after each. Never ask the owner to edit packet or spec files themselves: an option that changes the packet gives the exact wording it would put there, and says that choosing it means an amendment PR that you open and they merge (**Amend**). The two stops below have first lines and options of their own.
3. Release the claim and stop.

### A budget stop

`credit-check` printed `OVER` (exit 3) before a fix run (step 8, **Fix**: `next=fix`) or before a round (packet-review §1: `next=round`). The comment's first line is exactly:

```text
`packet:needs-human reason=budget next=<round|fix> round=<N> so-far=<n> step=<n> ceiling=<n> head=<sha>`
```

`next` is the step that didn't run. `round` is the round it belongs to: for `next=round`, the round that didn't start; for `next=fix`, the round whose findings the fix would answer. `so-far`, `step` and `ceiling` are the numbers the check printed. `head` is the PR's head now (`gh pr view <pr> --json headRefOid`). Below the first line, quote the line the check printed, then give these options, in this order:

1. **Raise:** comment `` `packet:budget max=<credits>` `` on the PR, as the comment's first words, with a whole number at least the `total` the check printed, then `/packet-dispatch resume <ID>`. A raise holds for the rest of this packet, and the newest one counts.
2. **Pass with follow-ups:** a settle at this head (**Settle**). Offer it only when `next=fix` and `head` is the head of the newest round in `board rounds <pr>`, so the head is the one the newest round reviewed. The owner comments on the PR with `` `packet:settle head=<head>` `` as the comment's only line, then resumes. You then open one follow-up issue per confirmed finding of round `<N>`, and the PR goes on to CI and the hand-off with no change and no further round. Name every blocking finding it would pass (its number in the round report, lens and file:line).
3. **Stop:** close the PR and move the item to Backlog.

With `next=round` there is no option 2: the round was to review a head no panel has seen.

### A model-tier stop

The host wouldn't start a round's reviewer (packet-review §2). The comment's first line is exactly:

```text
`packet:needs-human reason=model-tier agent=<agent> round=<N> head=<sha>`
```

`agent` is the reviewer agent the host refused, `round` the round that stopped, and `head` the head it was to review. Below the first line, quote the host's message as it gave it, then give these options:

1. Resume from a dispatcher session on a model at least as dear as the agent's (its agent file's `model:` line).
2. Resume in the Copilot harness.
3. Give the agent the dispatcher's class in `models.agents`, merge that, and run the installer again; then resume. This weakens what the agent's tier means: its reviews run on the dispatcher's models.
4. Stop: close the PR and move the item to Backlog.

There is no settle: the head isn't one a panel reviewed.

## Amend (the owner's answer changes the packet)

The packet file, as merged on the default branch, is the contract: the brief, the scope check and the reviewers read it there, and the implementer may not edit it. When the owner's answer changes what it says (the goal, an acceptance criterion, Tests to run, Out of scope, Owns, touchpoints, dependencies or locks), you put the answer into the packet file through a small pull request, and the owner's merge approves it. Never ask the owner to edit the file, and never change it on the packet branch.

1. **The answer must say exactly what changes.** If it can be read two ways ("drop the timing criterion; anything under 50 ms is fine"), ask once more (**Needs human**), quoting it, with the exact wording each reading would put in the packet.
2. **Edit in a temporary worktree**, outside the repository, from the default branch: `git worktree add <temp>/amend-<id> -b amend/<id in lower case>-<2 to 4 words> origin/<defaultBranch>`. Change only the packet file (and the plan's packet index row, if the title, priority, size or dependencies change), and only as the answer approves.
3. **Validate** from that worktree: `pwsh -File <kit>/.github/skills/packet-plan/scripts/validate-packets.ps1 -Phase <phase>` prints no ERROR. A change to Owns, dependencies or locks can collide with other packets; the validator says so, and that goes back to the owner.
4. **Open the PR.** Commit (`Amend <ID>: <what changes>`), push the branch, and `gh pr create --base <defaultBranch> --head <branch> --title "Amend <ID>: <what changes>" --body-file <file>`. The body links the owner's answer, quotes it unless it contains a closing keyword (`close`, `fix` or `resolve` and an issue number), and shows each changed line before and after. Nothing in it may close the item when it merges. No review panel runs on it: it changes no code, and the owner reviews it by merging. Then `git worktree remove <temp>/amend-<id>`.
5. **Hand it to the owner.** Comment on the item, first line `` `packet:needs-human` ``: "Amendment PR #<n> puts your answer into `<packet path>`. Merge it, then `/packet-dispatch resume <ID>`." The status stays Needs human. Release the claim and stop.

On resume, `gh pr view <n> --json state`:

- open: still waiting. Release and stop.
- closed without merging: the owner declined it. Ask again (**Needs human**).
- merged: `board sync -Phase <phase> -Ref origin/<defaultBranch>`, so the item shows the amended packet (if sync skips it because its body was edited on the board, or names it as misplaced in the tree, say so to the owner; the packet file is the contract either way). Never add `-Force`: that overwrites the owner's board edits and moves items. Then run Select's checks again for this packet, since the amendment may have changed its dependencies or locks:
  - `board deps <ID> -Json`: its `Verdict` must be START. Read the verdict, not the exit code, which is 1 while the status is Needs human.
  - `board locks <ID>` exits 0, when the packet lists locks.
  - No open contract question names one of its dependencies.

  A packet that is or was stacked waits too: an amendment lands on the default branch, so it carries on only after its dependency has merged (**Stacked packets**). If anything makes it wait:
  - with no packet branch yet, `board set <ID> "Status=Ready"`, tell the owner what it waits for, release and stop; any session dispatches it once it can start;
  - with a branch or a PR, keep it Needs human: comment `` `packet:needs-human` `` "The amendment is merged; <ID> waits for <what>. Run `/packet-dispatch resume <ID>` once that is done." Release and stop. A fresh dispatch would start over on the same branch name, so this work resumes only through `resume`.

  Otherwise:
  - no packet branch yet: `board set <ID> "Status=In progress"` and go to step 3 (Branch) from the new default branch; step 4 writes the brief from the amended packet;
  - a branch but no PR: `board set <ID> "Status=In progress"`, merge `origin/<defaultBranch>` into the branch (never rebase), post a new brief from the amended packet (step 4; its marker's `base=` is the default-branch commit you merged), and carry on at step 5;
  - an open PR: `board set <ID> "Status=In review"`, merge `origin/<defaultBranch>` into the branch, post a new brief as above, and carry on at step 5 with only what the amendment changed. Verify (step 6), push, and run a review round (step 8): the panel judges against the amended packet. With the rounds used up, **Needs human** instead: the owner settles it.

  The scope check and the reviewers read the amended packet from then on.

## Settle

The owner can settle a PR in two cases. **After the last round**, a settle stands in for the round that can't run, and can carry the owner's own change. **Before the last round**, a settle can only pass the newest round's findings with follow-ups, at the head that round reviewed, and only after a budget stop before a fix (the narrow settle: the owner's decision, question 7 of the solo-budget plan). The rounds are used up when the newest round's number in `board rounds <pr>` equals `review.maxRounds` (review-scope's `Settings.MaxRounds`, read at the base).

### After the last round

When the rounds are used up and something still needs a change (a blocking finding, a conflict resolution, a CI fix), the panel can't run again. The owner can **settle** it on the PR instead: they push the fix themselves, or describe it exactly, in a **PR comment** whose first line is `` `packet:settle head=<sha>` ``, where `<sha>` is the PR head they looked at (with their own fix pushed, that's their fix's commit), then run `/packet-dispatch resume <ID>`.

A settle counts only if `board rounds <pr> -Json` lists it as a `settle-request` that is newer than the last round, has a `head`, and isn't `Consumed` (a settle-check already followed it). `board` reads only trusted authors (the signed-in user and `trustedAuthors`, as merged on the default branch); a settle anywhere else, or from anyone else, is ignored. And the PR's head right now (`gh pr view <pr> --json headRefOid`) must equal the request's `head`: a commit pushed after the owner looked isn't covered, so ask again (**Needs human**). On resume, with such a request:

1. Claim. `git fetch origin`, then `git merge --ff-only <the request's head>`. If the request describes a change (its `Body`), apply exactly that on top, as one commit `Settle (<ID>)`; otherwise the owner's pushed commits are the settle.
2. Verify as in step 6 (clean tree and kit first, scope, the packet's tests). A problem goes back to the owner (**Needs human**), never to another panel round.
3. Check the claim and push (never with `--force`).
4. Comment on the PR: `` `packet:settle-check head=<the pushed head sha>` `` with what you ran and the results. That head counts as reviewed in step 9.1: the owner reviewed the settle themselves.
5. Continue at step 9.1 (the reviewed head is now the settle-check's), then 9.2 and 9.3, and in the hand-off say "settled by the owner after round <N>".

### Before the last round: pass with follow-ups

Before the last round, a settle counts only when all of these hold, as well as the checks above (trusted, newer than the last round, a `head`, not `Consumed`):

1. the item's last Needs human (`board marker <ID> needs-human -Json`) is `reason=budget` with `next=fix`, and the request is newer than it;
2. the request's `head` is the `head` of the newest `round` in `board rounds <pr> -Json`, and the PR's head now (`gh pr view <pr> --json headRefOid`);
3. it describes no change: its `Body` holds nothing but the marker line and white space. Anything more reads as a change, and a change needs a round.

Any other settle before the last round isn't an answer (**Resume**, **After a stop**). One that counts never carries a code change: it passes that round's confirmed findings as follow-ups, so nothing a panel hasn't reviewed reaches Ready to merge this way. On resume, with such a request:

1. Claim. `git fetch origin`, then the checkout must be clean and at the request's head (`git merge --ff-only <head>` if it is behind; anything else goes back to the owner, **Needs human**). Nothing is committed or pushed.
2. **Follow-ups.** Read that round's report on the PR (its `CommentId` in `board rounds <pr> -Json`). Open one follow-up issue per confirmed finding, under packet-review §5's rules: the `<labels.followUp>` label, a link to the PR and the finding, and for a contract finding the title `<ID> contract: <the question>` and the `<labels.needsHuman>` label too. A finding an earlier round already filed (packet-review §3, Already filed) isn't filed again. If a label is missing, or opening one fails, stop with no settle-check: release and report. A later resume opens only the ones not yet open.
3. Check the claim. Comment on the PR: `` `packet:settle-check head=<the request's head>` `` "Passed with follow-ups after round <N> (budget stop): #…". That head counts as reviewed in step 9.1, as the panel's round reviewed it.
4. `board set <ID> "Status=In review"`, then continue at step 9.1, 9.2 and 9.3, and in the hand-off say "settled by the owner after round <N>: its findings are follow-ups #…". The next round, if a conflict or a CI fix brings one, passes `-Confirmed -` to review-scope (packet-review §1).

## Status

`board next` (what can start), then the owner's queue from `board show`: Ready to merge (the owner merges), Needs human (the owner decides), and human tasks whose dependencies are done. Add the open contract questions (`gh issue list --repo <repo> --state open --label <labels.followUp> --label <labels.needsHuman> --limit 200 --json number,title`): each blocks the packets that depend on the packet its title names, even when `board next` says START. For health, the critical path and merge order, use `/packet-progress`.
