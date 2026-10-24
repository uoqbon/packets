# Packet workflow kit for GitHub Copilot

A way of working for building planned software with several coding agents at once, packaged as GitHub Copilot custom agents and agent skills for VS Code. It came out of a private project where it ran on Claude Code; this is the portable, provider-neutral version.

```text
implementation plan
   │  /packet-plan        cut into task packets: owned paths, contracts, dependencies, tests, lenses
   ▼
docs/plan/<phase>/plan.md + packets/<ID>.md      ── reviewed as a pull request
   │  /packet-board       one issue / work item per packet (GitHub Project, GitHub issues, Azure Boards)
   ▼
board: Backlog → Ready → In progress → In review → Ready to merge → Done      (Needs human on the side)
   │  packet-dispatcher   one session per packet, each in its own worktree:
   │                      claim → brief → packet-implementer → verify → PR → review panel → hand off
   ▼
owner merges                       /packet-progress: health, critical path, what to merge and start next
```

The ideas that make it work:

- **A packet is one PR** that one agent can build and a panel can review in at most three rounds.
- **Packets own paths.** Two packets that can run at the same time never own the same file; shared files (startup, routing, manifests) allow one small edit each. A validator checks this before anything starts.
- **Contracts first, fakes first.** The first packets land shared types and fakes for external services, so everything after can be built in parallel and tested offline.
- **Claims are leases** on the board item, so two sessions never work one packet.
- **Briefs state verified facts** (real names, signatures, paths at the base commit), so implementers don't explore or guess.
- **Review is a panel of narrow lenses** on a tier chosen from the diff, with every finding triaged against the code. At most two reviewers at a time, at most three rounds.
- **Agents never merge.** The owner is the only merge gate; a packet is Ready to merge only after the panel passed and CI passed on the reviewed head.

## What's inside

| Path | What it is |
| --- | --- |
| `agents/packet-dispatcher.agent.md` | The lead for one packet. Pick it in the agents dropdown. |
| `agents/packet-implementer.agent.md` | Builds one packet from a brief. Subagent only. |
| `agents/packet-reviewer-{light,standard,deep}.agent.md` | One lens (or a small group, `review.lensesPerReviewer`) at one of three review tiers, at low, medium or high reasoning effort. Subagents only. |
| `skills/packet-plan/` | Plan → packets; templates; `validate-packets.ps1`. |
| `skills/packet-board/` | Board setup, sync and reads; `board.ps1` and the providers (`github-project`, `github-issues`, `azure-boards`, `local`). |
| `skills/packet-dispatch/` | The dispatcher's procedure; brief and PR templates; `check-scope.ps1`. |
| `skills/packet-review/` | The review panel; eleven lenses; round report template; `review-scope.ps1`. |
| `skills/packet-progress/` | Phase health and next moves; `progress.ps1`. |
| `hooks/` | A `preToolUse` hook that refuses to start `packet-dispatcher` as a subagent (`packet-workflow.json` and `packet-dispatcher-guard.ps1`). |
| `templates/` | The config template and the repository-instructions block. |
| `install.ps1` | Installs or upgrades the kit in a repository. |
| `tests/run-tests.ps1` | Offline tests for every script (pwsh and git only). |
| `docs/cost.md` | What the workflow costs in GitHub AI Credits, the levers, and a budget profile. |

## Requirements

- **VS Code** with GitHub Copilot: agent mode, custom agents (`.github/agents`) and agent skills (`.github/skills`, `chat.useAgentSkills`, on by default).
- **PowerShell 7.2+** (`pwsh`) on Windows, macOS or Linux. Every script is PowerShell; the instructions call them with `pwsh -File`, which works from any terminal.
- **git 2.38+**, the **GitHub CLI** (`gh`) signed in. Pull requests always live on GitHub.
- For a GitHub Project board: `gh auth refresh -s project`.
- For Azure Boards: `AZURE_DEVOPS_EXT_PAT` (Work Items read & write), or the Azure CLI signed in.

## Install

Clone a release of this repository next to (not inside) the repository you want to set up, then run its installer against that repository:

```bash
git clone --branch v0.1.0 https://github.com/uoqbon/packets.git
```

```bash
pwsh -File packets/install.ps1 -Target <path to the repository> -WithInstructions
```

It copies the agents to `<repo>/.github/agents/`, the skills to `<repo>/.github/skills/` (where Copilot discovers them) and the hook to `<repo>/.github/hooks/`, creates `.github/packet-workflow.json` from the template with the repository and default branch filled in, and with `-WithInstructions` adds the workflow's rules to `.github/copilot-instructions.md` between markers. `-DryRun` shows what it would do.

To upgrade, check out a newer release (`git -C packets fetch --tags`, then `git -C packets checkout <tag>`), read what it changes in [CHANGELOG.md](CHANGELOG.md), and run the same command. To follow `main` between releases instead, clone without `--branch` and upgrade with `git -C packets pull`. The installer records hashes in `.github/packet-workflow.kit.json`, replaces only files you haven't changed since the last install, and lists the ones it kept (`-Force` replaces them). Put project-specific review lenses in `.github/packet-lenses/<name>.md`; the kit never touches that folder, and a lens there overrides the kit's lens of the same name.

Commit what it installs in a pull request; Copilot reads the files from the checkout, and worktree sessions see only committed files.

## Configure

`.github/packet-workflow.json`:

| Key | Meaning |
| --- | --- |
| `repo`, `defaultBranch` | The GitHub repository (`owner/name`) and its default branch. |
| `packetPrefix`, `humanPrefix` | Packet IDs are `<packetPrefix>-<n>`, human tasks `<humanPrefix>-<n>`. |
| `paths.plans` | Where phases live: `<plans>/<phase>/plan.md` and `<plans>/<phase>/packets/<ID>.md`. |
| `paths.decisions` | Each packet's decision record, e.g. `docs/decisions/{phase}/{packet}.md`. |
| `paths.lenses` | Project lenses (default `.github/packet-lenses`). |
| `board.provider` | `github-project`, `github-issues`, `azure-boards` or `local`; settings per provider under `board.*` ([providers](skills/packet-board/providers.md)). |
| `labels` | Label (or tag) names for packets, human tasks, needs-human and follow-ups. |
| `commands.ci` | The full local gate the dispatcher runs once before opening a PR (e.g. `dotnet build && dotnet test`). Packet-level tests come from each packet. |
| `guardrails.protectedBranches`, `forbiddenCommands`, `rules` | What no agent may do here: production deploys, cloud CLIs, release targets. Copied into every brief. |
| `locks` | Exclusive resources (`migrations`, a lockfile, a generated client), each with path globs. |
| `trustedAuthors` | Other people (GitHub logins; Azure DevOps unique names) whose claims, briefs, round reports and settles count. The signed-in user always counts; markers from anyone else are ignored, so a commenter can't forge a passed round. List everyone who runs dispatchers. |
| `stacking` | Allow a packet to start on a dependency that is Ready to merge but not yet merged (one deep). Off by default. |
| `remotes` | Packets in other GitHub repositories that this repository's packets depend on, by ID prefix: `{ "API": { "repo": "acme/api" } }`, plus `label` when that repository's packet label isn't `labels.packet`. A packet can then list `API-3` under **Depends on**. It can start once the issue titled `API-3 · …` with that repository's packet label in `acme/api` is closed as completed, and no such issue is open there. The other repository runs its own kit, board and review. This one reads only the state of those labelled issues. |
| `claims.leaseMinutes` | How long a claim lasts after its newest claim comment, by the board's clock (30). `board claim` renews it only once a third has passed and otherwise checks without writing, so the work between two checks should take under two thirds of it (20 minutes), or under the minutes a `renewal deferred` line names. Raise it if implementer runs or test suites take longer. Change it, either way, only while `board claims` shows no live claim: sessions that read different leases can both hold a packet. |
| `models.strong`, `standard`, `light` | The models each agent asks for, in preference order: *strong* for the dispatcher and the deep reviewer, *standard* for the implementer and the standard reviewer, *light* for the light reviewer. The installer writes them into the agents' `model:` lines; change them and run the installer again. |
| `review.maxRounds`, `maxParallelLenses` | 3 and 2: rounds per PR, and reviewer runs at once. |
| `review.lensesPerReviewer` | Lenses one reviewer run covers (1; up to 3). Every lens still runs, at the round's tier; 2 saves about 16% of a phase's credits ([cost](docs/cost.md)). |
| `review.shouldFixPassFromRound` | From this round on, a round whose confirmed findings are all should-fix passes and files them as follow-ups (unset or `null`: `maxRounds`, so only the last round). A blocking finding still gets a fix and another round (in the last round it goes to the owner, as before). 2 saves about 20% of a phase's credits. |
| `review.agents` | The reviewer agent per tier, 1 to 3. A `"4"` from an install before tiers 3 and 4 merged runs tier 3, unless it is the kit's old `packet-reviewer-max`; move it to `"3"`. |
| `review.maxPaths`, `deepPaths` | Regexes for the project's critical paths: either raises a change to tier 3, the top. They only ever raise a tier. |
| `review.lensPaths`, `concurrencyPattern` | Which paths and added lines call for which lens. |
| `review.lensOrder` | The order lenses run in, riskiest first. |
| `sizes` | Weights of S, M and L for progress and the critical path. |
| `budget.monthlyCredits`, `budget.creditsPerRun` | The team's monthly AI-credit allowance, and the credits per run (dispatcher, implementer and reviewer by tier and size) that `progress.ps1 -Credits` estimates with. The defaults come from [cost.md](docs/cost.md)'s model, with tier 3 priced at what tier 4 cost before the two merged; calibrate them against the billing AI usage report. |

## Use

1. **Plan.** In Copilot Chat (Agent): `/packet-plan docs/specs/checkout.md phase-2-checkout`. It writes the phase plan and packet files and runs the validator until it reports no errors. Review them as a pull request and merge it.
2. **Board.** `/packet-board setup`, then `/packet-board sync phase-2-checkout`. Each packet becomes an issue or work item, with its dependencies linked and its status set from the packet's `Initial status`. If the plan names a root item (an `**Epic:**`, `**Feature:**` or `**User Story:**` line, by the plan's size), each packet goes under it: on Azure Boards as a tree that follows the process's levels, Epic > Feature > User Story > Task; on GitHub as sub-issues.
3. **Dispatch.** Open one agent session per packet, each in its own worktree (in the Agents view, *New Worktree*; or `git worktree add ../repo-pkt-03 origin/main` and open that folder). Pick **packet-dispatcher** and type `/packet-dispatch` (it takes the next startable packet) or `/packet-dispatch PKT-03`. Type the slash command yourself: it needs no judgement of who started the dispatch. A plain `dispatch` in a dispatcher chat leaves the dispatch skill to judge that the dispatcher's own check passed, and in one test run that judgement turned the person away. It claims the packet, briefs and runs the implementer, checks scope and tests, opens the PR and runs the review panel, then sets Ready to merge once CI passes on the reviewed head.
4. **Merge.** You merge. The item closes; `board reconcile` (run by every dispatcher's preflight) marks it Done.
5. **Track.** `/packet-progress` anytime (ask about cost, and it adds `-Credits`: an estimate of each packet's AI credits against `budget.monthlyCredits`): health, the merge order that unblocks the most, what can start, what waits on you, the critical path, late and stale work.

When a dispatcher needs you, the packet goes to **Needs human** with a question and options on the item; answer there and type `/packet-dispatch resume PKT-03` in a dispatcher session. If your answer changes what the packet file says (a criterion, the goal, its paths), the dispatcher doesn't ask you to edit it: it opens a small `Amend PKT-03: …` pull request for the packet file, and your merge approves the change; resume again after merging. When a round passes with a should-fix question about a contract other packets build on (the last round, or from `review.shouldFixPassFromRound` on), it opens a follow-up titled `PKT-03 contract: …` with the `needs-human` label, and no dispatcher starts a packet that depends on PKT-03 until you answer it and remove the label (or close the issue); `/packet-progress` lists these. After the last review round, you can **settle** a remaining problem yourself: push or describe the fix, comment `` `packet:settle head=<the PR head you looked at>` `` on the PR, and resume. The dispatcher checks scope, tests and CI, without another panel round; a commit pushed after your settle isn't covered by it.

## Copilot specifics

- **Discovery.** Copilot reads custom agents from `.github/agents/` and skills from `.github/skills/`. This repository is the kit's source and is **not** discovered from here; `install.ps1` copies it into place. The settings that used to add extra locations (`chat.agentFilesLocations`, `chat.agentSkillsLocations`) are deprecated and only work in the Local harness.
- **Harnesses.** In the **Local** harness, the dispatcher starts subagents with the Run Subagent tool, limited by its `agents:` list; subagents are stateless and can't start further subagents (unless `chat.subagents.allowInvocationsFromSubagents` is on, which the kit doesn't need); handoff buttons work. In the **Copilot** harness (Copilot CLI sessions, worktree sessions), turn on `github.copilot.chat.cli.customAgents.enabled` so the custom agents are available; `reasoning-effort` in the reviewer agents is honoured there.
- **Who can start which agent.** The four subagents have `user-invocable: false`, which keeps them out of the agents dropdown; VS Code's docs say this applies to the Local and Copilot harnesses, and Copilot CLI hides them from `/agents`. The dispatcher has `disable-model-invocation: true`, which asks hosts not to offer it to other agents. VS Code documents the key (an agent that lists it by name in its `agents:` overrides it; no kit agent does), and Copilot CLI has read it since 0.0.411. Neither host enforces it everywhere yet. VS Code's Copilot SDK agent host loses the key on the way to the CLI runtime, so the dispatcher shows up in the `task` tool's agent list ([microsoft/vscode#340861](https://github.com/microsoft/vscode/issues/340861)). Local's Run Subagent doesn't check the key at all; it only leaves the agent out of the list the model sees, and a call that names no agent runs a copy of the caller, past the `agents:` list too ([microsoft/vscode#333369](https://github.com/microsoft/vscode/issues/333369)).

  So the kit installs a hook, `.github/hooks/packet-workflow.json`, that the host enforces. The Copilot runtime, which VS Code's Copilot harness, the Copilot app and Copilot CLI share, runs `packet-dispatcher-guard.ps1` before each `task` call. The script refuses a call whose arguments name `packet-dispatcher`, however its prompt reads. That matters because a subagent gets its task as an ordinary user turn: in one test run the dispatcher took an agent's one-word `status` task for a person's, and the hook doesn't need it to tell them apart. It lets every other call through, including one it can't read, so it never stops the dispatcher's own subagents. The hook's commands pass on only the script's refusal. Copilot's runtime would deny a call whose hook failed, so the commands let the call through when:
  - `pwsh` isn't on the hook's PATH;
  - the script is missing;
  - the script fails (an older pwsh, an execution policy).

  On such a machine the guard is off, without a word. The hook also covers only starts through the subagent tool, not a new session an agent opens from a terminal (`copilot --agent=packet-dispatcher -p …`, `code chat -m packet-dispatcher …`). There, and wherever the hook doesn't run, only the checks below stand. It doesn't run:
  - outside a trusted workspace, or where an organization has turned repository hooks off;
  - in the Local harness without `chat.useHooks`. With it, Local runs the hook before every tool call, since it ignores the matcher. The script lets anything but a dispatcher start through once it has read the call, but starting `pwsh` adds a fraction of a second to each call, more on Windows, where Local starts Windows PowerShell first.

  Behind the hook, the dispatcher also checks for itself, before it claims anything: if another agent started it, it stops and says so. In the Local harness, a subagent has no tool to start subagents (unless `chat.subagents.allowInvocationsFromSubagents` is on), which the dispatcher can check for certain. In the Copilot harness, subagents keep that tool, so the check is only the model's judgement of who wrote its task. The dispatcher also names every agent it starts, and the four subagents have no subagent tool. The `packet-dispatch` skill, the dispatcher's procedure, doesn't have the key, so any agent can load it on its own, including one the dispatcher's check just turned away. So the skill checks too, before its Preflight (`## Only a person starts a dispatch`): it goes on only for a person's own `/packet-dispatch` in this chat, typed as a slash command or in their prompt, or inside a `packet-dispatcher` that passed its own check, and otherwise stops before any claim with one line. That is the model's judgement of who asked, in every harness; like the dispatcher, it also stops without a subagent tool (unless the request is `status`), which is certain for a Local subagent. The key wouldn't replace the check: on a skill it only takes it out of the model's skill list and leaves the person's `/packet-dispatch`, and an agent with a read tool could still open `SKILL.md`. Even that narrower key would lock people out on two hosts: before VS Code 1.141.0, the Copilot harness skips a typed `/name` of such a skill without a word and sends the rest as a plain prompt ([microsoft/vscode#331477](https://github.com/microsoft/vscode/issues/331477)); Copilot CLI runs a typed `/packet-dispatch`, but a request in a prompt (the form GitHub's CLI docs show) and `copilot -p`, which has no slash commands, leave it to the skill tool, which answers `Skill not found`, although the 1.0.74 changelog says the key is fully honoured ([github/copilot-cli#4438](https://github.com/github/copilot-cli/issues/4438), open; in the Copilot app a typed `/name` can fail too). Add the key when #4438 is fixed and the kit requires VS Code 1.141 or later.
- **Models.** Each agent lists models in preference order (`model:`); the first one available is used. The installer writes those lines from `models` in `.github/packet-workflow.json`, so set that map to what your organization offers, or, with your own API key (BYOK), to the names your model picker shows, and run `install.ps1` again; don't hand-edit the agent files (an upgrade would keep them as locally changed). You can list names from both harnesses in one class, since names that aren't available are skipped. If none is offered, the dispatcher asks you once for a model per class instead of choosing per agent. A Local subagent won't start on a model in a higher cost tier than the session's, so run the dispatcher on a model at least as capable as `packet-reviewer-deep`'s.
- **Tool budget.** With many MCP servers enabled, a session can offer more tools than the model accepts (Copilot warns that some tools "were not provided to the model"). The packet agents name only the tools they need, and an end-to-end run went through with the warning showing. If a subagent reports a missing terminal or edit tool, turn off the MCP servers this workspace doesn't need. Every tool's description is sent with every model call, so they also cost credits: about 14% more per packet with Copilot's 128-tool limit reached ([cost](docs/cost.md)).
- **Terminal approvals.** The scripts run through the terminal tool. For a second line of defence against the commands agents must never run, add require-approval entries, for example:

  ```json
  "chat.tools.terminal.autoApprove": {
    "gh pr merge": false, "gh workflow run": false, "gh run rerun": false,
    "/^git push .*(--force|-f\\b)/": false, "az": false
  }
  ```

- **The real merge gate** is server-side: protect the default branch (require a pull request and an approving review from a person) so that no token an agent holds can merge.

## Safety model

| Rule | Where it is enforced |
| --- | --- |
| Agents never merge, approve, force-push or run CI | agent and skill instructions, `guardrails` in every brief, terminal approval settings, branch protection |
| An implementer stays inside its paths | the brief; `check-scope.ps1` before every PR; the architecture lens |
| Two concurrent packets never own one file | `validate-packets.ps1` (exact for existing files, prefix check for new ones) |
| One holder per lock | the validator (ordering), `board locks` before dispatch, `check-scope.ps1` |
| A packet branch can't weaken its own review | dispatcher and panel run every script from a **pinned kit** (`.github/skills` exported from the default branch with `git archive` before any script runs); the scripts read the config and packet files at the base (`board` at origin's default branch, found from `refs/remotes/origin/HEAD`); kit, agent, hook and project-lens paths raise the review tier to 3, the top, and check-scope rejects them unless owned; the panel's limits (rounds, the should-fix rule, lenses per run) come from review-scope, which reads them at the base, and reviewers read lens and packet texts with `git show` from trusted commits |
| Two sessions never work one packet | the claim lease on the board item: the oldest trusted claim in the lease window holds, by the board's clock (`board claim`). It posts a renewal only when one is due, always reads after posting, and keeps a holder's older claim comments until release; a check that posts nothing re-reads the window its newest comment won. The skills check before long steps and before every push, PR, board write and hand-off, and stop on `LOST` or exit 2 |
| A dependency in another repository counts as done only when its issue there is closed as completed | `board deps`, `board next` and `progress.ps1` read, over REST, only the state of the issues there that carry its packet label and that ID. They never read those issues' comments, status labels or markers, and never use an item on this board with the same ID. `remotes` is read from the config on the default branch. Anyone who can close or label issues in that repository can unblock the packet that waits on it, so list only repositories whose maintainers you trust. A failed lookup exits 2 |
| Nobody else can forge a brief, a passed round, a settle or an answer | `board` reads markers and answers only from the signed-in user and `trustedAuthors`, taking that list from the config on the default branch |
| Only a person starts the dispatcher | the kit's `preToolUse` hook (`.github/hooks/`), which the host runs before each subagent start and which refuses one of `packet-dispatcher`, where the host runs repository hooks (not a session an agent opens from a terminal); hook files are review machinery, so a packet that doesn't own them can't change them, and a change raises the review to the top tier; `disable-model-invocation: true` where the host honours it; the dispatcher's own check, which stops before any claim when another agent started it (certain in Local, the model's judgement in Copilot); the `packet-dispatch` skill's own check, which stops the same way unless a person typed `/packet-dispatch` or started the dispatcher (the model's judgement), and without a subagent tool (certain for a Local subagent); the dispatcher names every subagent it starts; the subagents have no subagent tool |
| A failed check never counts as a pass | every script exits 2 on an error, and the instructions stop on exit 2 |

## Tests

```bash
pwsh -File tests/run-tests.ps1
```

It builds a throwaway repository with a sample phase and exercises the validator, the board (local provider: sync, verdicts, claims, markers, reconcile), review scope, tiers and lens grouping, scope checks, progress, the credit estimates and the installer. It runs the Azure Boards provider's tree building and status mapping against an in-memory Azure DevOps ([tests/azure-boards-fake.ps1](tests/azure-boards-fake.ps1)), which keeps links, revisions, states per type and work item comments the way the service does, with a clock of its own: claims are checked there for renewal only when due, takeover after a lapse, a competitor racing a renewal, and clock skew. It needs no network.

**Inside Copilot**, [tests/copilot-e2e.prompt.md](tests/copilot-e2e.prompt.md) is a staged end-to-end test plan for a sandbox repository. It runs discovery and static checks, the offline suite and the installer, then `/packet-plan` on a mini spec, board setup and sync, a single dispatch, two parallel dispatches with a merge conflict, the Needs human and resume path, and safety probes, and ends with a report. Paste it into Copilot Chat (Agent), or copy it to the sandbox's `.github/prompts/` to run it as `/packet-kit-e2e <stage>`. It stops at each step that needs you (opening dispatcher sessions, merging) and keeps its state in `.packet-e2e/`, which it excludes from git.

[tests/copilot-e2e-azure-story.prompt.md](tests/copilot-e2e-azure-story.prompt.md) runs the same stages on Azure Boards, for a team whose product owner has already written the User Story: the plan names it with `**User Story:** AB#<n>`, and the packets become Tasks under it. It adds checks that sync builds that tree and nothing else (no Features, the story's own fields and its other children untouched, with any development links the Azure Boards app adds reported apart from the kit's changes), a dry run that writes nothing, a Task moved under another parent and back with `-Force`, a root of the wrong type, and claims, briefs and answers as work item comments. It needs a PAT in `AZURE_DEVOPS_EXT_PAT`, and the Azure Boards app on the sandbox to close Tasks on merge (without it you close them by hand).

Before relying on a hosted provider, smoke-test it on a sandbox repository: `board setup -DryRun`, `board sync -DryRun`, a real `sync` of two packets, `board claim` from two terminals, `board set`, `board marker`, `board reconcile` after closing an issue. The GitHub providers were exercised against a live sandbox while this kit was built. The Azure Boards provider has run end to end once, through the Azure story prompt, before the fixes it led to. That run used a Basic-process project with a story (an Issue, in Basic) as the root and the Azure Boards app connected. Of those fixes, decoding the Markdown that Azure returns escaped has since been checked on that board with a live sync and marker reads; the rest haven't been through the prompt yet. Other processes, epic and feature roots, `markdown: false` and `targetDateField` are tested offline only.

## Known limitations

- **Run end to end inside Copilot twice, each time before the fixes it led to.**
  - All nine stages of `tests/copilot-e2e.prompt.md` ran in the Copilot harness on the kit as it was before it moved to this repository, with Claude models through the owner's API key, on labelled issues: planning, sync, a foundation packet through three review rounds, two dispatchers in parallel with a merge conflict, Needs human and resume, the safety probes and progress. Three implementation packets merged. Its failures led to the `models` map, the scope check's comparison base after a merge of the default branch, and the amendment PR for answers that change a packet.
  - All nine stages of `tests/copilot-e2e-azure-story.prompt.md` ran in VS Code's Copilot harness (VS Code 1.143.1) on the kit at `0a97b42`, on 2026-10-23 and 24, on a Basic-process Azure Boards project with a story as the root and the Azure Boards app connected. The config listed GPT-6.1 Sol, then Claude Sonnet 5.5, for every class; which model each agent ran on wasn't visible. Its base stages took the first run's three fixes through: the models map, the scope base after a resume merged the default branch, and the amendment PR. Three implementation packets merged, and a forged round from a second GitHub account and a forged answer from a second Azure DevOps account, both outside `trustedAuthors`, were ignored. Of 75 checks, 62 passed, 7 failed and 3 were blocked (one was `HOST`, two N/A). Five of the failures came from the verifier's own setup commit and PR, which named the story, so the Azure Boards app linked it; the other two led to the Markdown decoding and the dispatcher hook. Blocked: the model each agent ran on, the live claims of two dispatchers in parallel, and the brief after the amendment, since the resumed packet stopped at Needs human again.

  Not exercised live in either run: a lock collision, an approved amendment carried through to Ready to merge, the github-project provider end to end, and the cost profile. The fixes the Azure story run led to haven't been through a full run yet. Run the prompts on a sandbox repository before relying on the kit.
- **Azure Boards has met one live organization, before the fixes that run led to** (see *Inside Copilot* above). It used a Basic-process project with a story as the root; other processes, epic and feature roots, `markdown: false` and `targetDateField` are tested offline only.
- **Other repositories are read only for dependencies.** With `remotes`, a packet can wait for a packet in another repository, as long as that repository's board keeps its packets as GitHub issues (`github-issues` or `github-project`). Locks, contract questions (`<ID> contract: …` follow-ups) and pull requests are still looked up in this repository only. A packet never stacks on another repository's packet, and reviewers don't see the other repository's code.
- **Harnesses.** Written for the Local harness first. The Copilot harness needs `github.copilot.chat.cli.customAgents.enabled`; whether it runs two reviewer subagents at once depends on the harness (the panel falls back to one at a time). The Copilot cloud agent isn't wired in.
- **One identity, one machine.** The implementer runs with the same GitHub sign-in as the dispatcher, in the same clone. Its instructions forbid `gh` and comments, and `board` ignores other authors, but an agent that ignored its instructions could still post as you. The local checks also assume nothing rewrote the clone's git config (for example `origin`'s URL) or the pinned kit in the temp folder; check-scope reads the default branch from the remote rather than from local refs, but it can't defend against those. The PR's diff on GitHub and your review are the backstop: branch protection with a required human review is the gate that doesn't depend on instructions.
- **Copilot loads agents and skills from the workspace.** Scripts always run from the pinned kit, and the dispatcher re-reads skills from it, but the agent definitions (and a skill Copilot loads on its own) come from the checkout. If a packet branch changes `.github/agents/` or `.github/skills/`, `check-scope.ps1` flags it as MACHINERY and the dispatcher restores those paths from the base before any review.
- **A host can offer the dispatcher as a subagent** (see *Who can start which agent* above). The kit's hook refuses such a start where the host runs repository hooks, though not a dispatcher session an agent opens from a terminal. Elsewhere, nothing stops another agent from starting it except the dispatcher's own check, which is an instruction a model follows, not a host rule; in the Copilot harness it rests on the model's judgement alone. The e2e prompt records the listing as `HOST` in S1.4 and tests the guard with a harmless `status` start in stage 8. In the first run that did, the Azure story run in the Copilot harness, before the hook existed, the check failed: the dispatcher went on into its Preflight instead of refusing. The hook is tested offline against the input formats the host documents, and against the `task` call that run recorded. One live run has used it since: a rerun of that `status` start alone, in VS Code's Copilot harness on macOS. The hook refused the start and left `.git/FETCH_HEAD` and the `packet-kit-*` temp folders untouched. The dispatcher never started, so its own check wasn't reached. That run didn't cover the Local harness, Copilot CLI, the Copilot app, Windows or a dispatcher session an agent opens from a terminal. The `packet-dispatch` skill has a check of the same kind, meant to stop an agent that loads or reads the procedure on its own; it is also only an instruction, resting on the model's judgement in every harness (apart from a Local subagent's missing subagent tool). Stage 8 tests the judgement with a subagent's `status` start the same way; in the Azure story run the skill's check refused correctly.
- **Azure board-edit detection** compares against the item as read at the start of sync, so an edit made during a sync can be overwritten.

## Compared with the Claude Code original

Kept: packets with owned paths and touchpoints, contracts first, locks, one decision record per packet, the claim lease, verified briefs, scope checks, the lens panel with tiers, triage, three rounds, follow-ups, Needs human, CI on the reviewed head, the owner as the only merge gate.

Changed: PowerShell instead of Bash, so the scripts run on Windows; three board providers instead of one GitHub Project; packet files in the repository as the source of truth (sync renders board items from them); markers are visible code spans so they survive every board's renderer; one session per worktree with stateless subagents instead of a background implementer in a separate worktree; tiers configured per repository.

Left out, on purpose: the original's cloud-session token checks, its GraphQL budget accounting, the detailed CI-failure classification and the many recovery paths its dispatcher grew for one tight deadline. Add them back per project if you need them.

## Contributing

Issues and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) says how to test a change and what a pull request needs.

## License

[MIT](LICENSE).
