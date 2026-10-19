# Packet workflow kit for GitHub Copilot

A way of working for building planned software with several coding agents at once, packaged as GitHub Copilot custom agents and agent skills for VS Code. It came out of the Drafter project, where it ran on Claude Code; this is the portable, provider-neutral version.

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
| `agents/packet-reviewer-{light,standard,deep,max}.agent.md` | One lens at one review tier. Subagents only. |
| `skills/packet-plan/` | Plan → packets; templates; `validate-packets.ps1`. |
| `skills/packet-board/` | Board setup, sync and reads; `board.ps1` and the providers (`github-project`, `github-issues`, `azure-boards`, `local`). |
| `skills/packet-dispatch/` | The dispatcher's procedure; brief and PR templates; `check-scope.ps1`. |
| `skills/packet-review/` | The review panel; eleven lenses; round report template; `review-scope.ps1`. |
| `skills/packet-progress/` | Phase health and next moves; `progress.ps1`. |
| `templates/` | The config template and the repository-instructions block. |
| `install.ps1` | Installs or upgrades the kit in a repository. |
| `tests/run-tests.ps1` | Offline tests for every script (pwsh and git only). |

## Requirements

- **VS Code** with GitHub Copilot: agent mode, custom agents (`.github/agents`) and agent skills (`.github/skills`, `chat.useAgentSkills`, on by default).
- **PowerShell 7.2+** (`pwsh`) on Windows, macOS or Linux. Every script is PowerShell; the instructions call them with `pwsh -File`, which works from any terminal.
- **git 2.38+**, the **GitHub CLI** (`gh`) signed in. Pull requests always live on GitHub.
- For a GitHub Project board: `gh auth refresh -s project`.
- For Azure Boards: `AZURE_DEVOPS_EXT_PAT` (Work Items read & write), or the Azure CLI signed in.

## Install

```bash
pwsh -File .github/copilot/install.ps1 -Target <path to the repository> -WithInstructions
```

It copies the agents to `<repo>/.github/agents/` and the skills to `<repo>/.github/skills/` (where Copilot discovers them), creates `.github/packet-workflow.json` from the template with the repository and default branch filled in, and with `-WithInstructions` adds the workflow's rules to `.github/copilot-instructions.md` between markers. `-DryRun` shows what it would do.

Upgrades use the same command. The installer records hashes in `.github/packet-workflow.kit.json`, replaces only files you haven't changed since the last install, and lists the ones it kept (`-Force` replaces them). Put project-specific review lenses in `.github/packet-lenses/<name>.md`; the kit never touches that folder, and a lens there overrides the kit's lens of the same name.

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
| `claims.leaseMinutes` | How long a claim lasts without a refresh (30). |
| `review.maxRounds`, `maxParallelLenses` | 3 and 2. |
| `review.agents` | The reviewer agent per tier. |
| `review.maxPaths`, `deepPaths` | Regexes for the project's critical paths: tier 4 and at least tier 3. They only ever raise a tier. |
| `review.lensPaths`, `concurrencyPattern` | Which paths and added lines call for which lens. |
| `review.lensOrder` | The order lenses run in, riskiest first. |
| `sizes` | Weights of S, M and L for progress and the critical path. |

## Use

1. **Plan.** In Copilot Chat (Agent): `/packet-plan docs/specs/checkout.md phase-2-checkout`. It writes the phase plan and packet files and runs the validator until it reports no errors. Review them as a pull request and merge it.
2. **Board.** `/packet-board setup`, then `/packet-board sync phase-2-checkout`. Each packet becomes an issue or work item, with its dependencies linked and its status set from the packet's `Initial status`.
3. **Dispatch.** Open one agent session per packet, each in its own worktree (in the Agents view, *New Worktree*; or `git worktree add ../repo-pkt-03 origin/main` and open that folder). Pick **packet-dispatcher** and say `dispatch` (it takes the next startable packet) or `dispatch PKT-03`. It claims the packet, briefs and runs the implementer, checks scope and tests, opens the PR and runs the review panel, then sets Ready to merge once CI passes on the reviewed head.
4. **Merge.** You merge. The item closes; `board reconcile` (run by every dispatcher's preflight) marks it Done.
5. **Track.** `/packet-progress` anytime: health, the merge order that unblocks the most, what can start, what waits on you, the critical path, late and stale work.

When a dispatcher needs you, the packet goes to **Needs human** with a question and options on the item; answer there and run `resume PKT-03` in a dispatcher session. After the last review round, you can **settle** a remaining problem yourself: push or describe the fix, comment `` `packet:settle head=<the PR head you looked at>` `` on the PR, and resume. The dispatcher checks scope, tests and CI, without another panel round; a commit pushed after your settle isn't covered by it.

## Copilot specifics

- **Discovery.** Copilot reads custom agents from `.github/agents/` and skills from `.github/skills/`. This folder (`.github/copilot/`) is the kit's source and is **not** discovered; `install.ps1` copies it into place. The settings that used to add extra locations (`chat.agentFilesLocations`, `chat.agentSkillsLocations`) are deprecated and only work in the Local harness.
- **Harnesses.** In the **Local** harness, the dispatcher starts subagents with the Run Subagent tool, limited by its `agents:` list; subagents are stateless and can't start further subagents (unless `chat.subagents.allowInvocationsFromSubagents` is on, which the kit doesn't need); handoff buttons work. In the **Copilot** harness (Copilot CLI sessions, worktree sessions), turn on `github.copilot.chat.cli.customAgents.enabled` so the custom agents are available; `reasoning-effort` in the reviewer agents is honoured there.
- **Models.** Each agent lists models in preference order (`model:`); the first one available is used. Edit them to what your organization offers. A Local subagent won't start on a model in a higher cost tier than the session's, so run the dispatcher on a model at least as capable as `packet-reviewer-max`'s.
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
| A packet branch can't weaken its own review | dispatcher and panel run every script from a **pinned kit** (`.github/skills` exported from the default branch with `git archive` before any script runs); the scripts read the config and packet files at the base (`board` at origin's default branch, found from `refs/remotes/origin/HEAD`); kit, agent and project-lens paths raise the review tier to 4, and check-scope rejects them unless owned |
| Two sessions never work one packet | the claim lease on the board item |
| Nobody else can forge a brief, a passed round, a settle or an answer | `board` reads markers and answers only from the signed-in user and `trustedAuthors`, taking that list from the config on the default branch |
| A failed check never counts as a pass | every script exits 2 on an error, and the instructions stop on exit 2 |

## Tests

```bash
pwsh -File .github/copilot/tests/run-tests.ps1
```

It builds a throwaway repository with a sample phase and exercises the validator, the board (local provider: sync, verdicts, claims, markers, reconcile), review scope and tiers, scope checks, progress and the installer. It needs no network.

Before relying on a hosted provider, smoke-test it on a sandbox repository: `board setup -DryRun`, `board sync -DryRun`, a real `sync` of two packets, `board claim` from two terminals, `board set`, `board marker`, `board reconcile` after closing an issue. The GitHub providers were exercised against a live sandbox while this kit was built; the Azure Boards provider is written against the REST API documentation and has **not** been run against a live organization yet.

## Known limitations

- **Not yet run end to end inside Copilot.** The agent and skill files follow the current VS Code formats and parse cleanly, and every script they call is tested, but a full dispatcher → implementer → review panel run in Copilot Chat hasn't happened yet. Do that on a sandbox repository first and expect to tune the wording.
- **Azure Boards** is written against the REST documentation and hasn't met a live organization.
- **Harnesses.** Written for the Local harness first. The Copilot harness needs `github.copilot.chat.cli.customAgents.enabled`; whether it runs two reviewer subagents at once depends on the harness (the panel falls back to one at a time). The Copilot cloud agent isn't wired in.
- **One identity.** The implementer runs with the same GitHub sign-in as the dispatcher. Its instructions forbid `gh` and comments, and `board` ignores other authors, but an agent that ignored its instructions could still post as you. Branch protection with a required human review is the gate that doesn't depend on instructions.
- **Copilot loads agents and skills from the workspace.** Scripts always run from the pinned kit, and the dispatcher re-reads skills from it, but the agent definitions (and a skill Copilot loads on its own) come from the checkout. If a packet branch changes `.github/agents/` or `.github/skills/`, `check-scope.ps1` flags it as MACHINERY and the dispatcher restores those paths from the base before any review.
- **Azure board-edit detection** compares against the item as read at the start of sync, so an edit made during a sync can be overwritten.

## Compared with the Claude Code original

Kept: packets with owned paths and touchpoints, contracts first, locks, one decision record per packet, the claim lease, verified briefs, scope checks, the lens panel with tiers, triage, three rounds, follow-ups, Needs human, CI on the reviewed head, the owner as the only merge gate.

Changed: PowerShell instead of Bash, so the scripts run on Windows; three board providers instead of one GitHub Project; packet files in the repository as the source of truth (sync renders board items from them); markers are visible code spans so they survive every board's renderer; one session per worktree with stateless subagents instead of a background implementer in a separate worktree; tiers configured per repository.

Left out, on purpose: Drafter's cloud-session token checks, its GraphQL budget accounting, the detailed CI-failure classification and the many recovery paths its dispatcher grew for one tight deadline. Add them back per project if you need them.
