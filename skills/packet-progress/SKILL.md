---
name: packet-progress
description: "Report where a phase of packet work stands. Covers progress by size, priority and wave, what can start now, what is blocked and why, the owner's queue (merges, decisions, human tasks), which finished packets would unblock the most, the critical path, late and stale work, priority inversions and board drift, with a health verdict and the next moves. Use when asked about progress, status, the backlog, what's next, what's blocked, priorities, dependencies, the critical path, or whether a phase is on track."
argument-hint: "[phase] [post]"
---

# Packet progress

You give the owner an honest picture of a phase and the few moves that matter most next. The numbers come from a script; the judgement is yours.

## Gather

```bash
pwsh -File .github/skills/packet-progress/scripts/progress.ps1 [-Phase <phase>] -Json
```

Run it from a checkout of the default branch (or from a dispatcher's pinned kit). It reads the packet files as merged on `origin/<defaultBranch>` (`-WorkingTree` for local files) and the board, and returns for each phase:

| Field | What it is |
| --- | --- |
| `Health`, `HealthReasons` | on track, at risk or off track, and why (P0 late or waiting on the owner → off track; anything late, P0 due soon and not started, stale, inverted or stuck → at risk) |
| `Totals` | packets, human tasks, and progress weighted by size: `DonePercent` (merged) and `LandedPercent` (merged or Ready to merge) |
| `Counts`, `ByPriority`, `ByWave` | status counts; done/total per priority and per wave |
| `Startable`, `Blocked` | Ready packets that can start (START/STACK), and Ready ones that can't, with reasons |
| `OwnerQueue` | `ReadyToMerge` (oldest first), `NeedsHuman`, `HumanTasksNow` (dependencies done) |
| `Leverage` | unfinished packets whose completion would let the most Ready packets start |
| `CriticalPath` | the heaviest chain of unfinished packets, by size |
| `Late`, `DueSoon`, `Stale` | past target; due within two days and not started; no update for 24 hours (`-StaleHours`) |
| `Inversions`, `WaitingOnBacklog` | a packet waiting on lower-priority work; a packet waiting on one parked in Backlog |
| `Drift` | packet files missing from the board, closed items not Done, Done items still open |
| `Credits` (with `-Credits`) | an **estimate** of the AI credits each packet's runs cost, from its PR's trusted round markers (rounds, tier, lenses, reviewer runs, fix rounds) and `budget.creditsPerRun`; the phase total, the average per finished packet, this month's credits against `budget.monthlyCredits`, and how many more packets fit this month at that average. Resume sessions and CI-fix runs leave no marker and aren't counted. |

Without `-Json` it prints the same as text. `-Credits` reads every packet PR's comments, so add it only when the owner asks about cost or budget. For a question about one packet, `board deps <ID>` and `board get <ID>` (`board` is `pwsh -File .github/skills/packet-board/scripts/board.ps1`) are cheaper.

## Judge

The script can't see everything; check before you advise:

- **Merges first.** Ready-to-merge PRs are the cheapest progress. Order them by leverage (what each unblocks) and then age. A Ready-to-merge PR whose head moved since its hand-off needs `/packet-dispatch resume <ID>` before it merges.
- **Owner decisions.** Read each Needs human item's last `packet:needs-human` comment and restate the question in one line, with the recommended option. Then list the open contract questions (`gh issue list --repo <repo> --state open --label <labels.followUp> --label <labels.needsHuman> --limit 200 --json number,title`; titles `<ID> contract: …`): each blocks every packet that depends on `<ID>` until the owner answers it and removes the label or closes the issue.
- **Dispatch capacity.** The number of Startable packets, minus those a contract question blocks, is the most sessions worth running now (one packet per session, each in its own worktree). Recommend the P0s on the critical path first.
- **Schedule.** Compare the critical path's remaining weight with the time left to the phase's next milestone (from its `plan.md`). If it doesn't fit, say what to cut: candidates are P2 and P3 packets off the critical path, or splitting the heaviest packet on it.
- **Backlog.** An inversion or a packet waiting on Backlog is a planning bug: propose raising the dependency's priority, promoting it from Backlog, or dropping the dependency.
- **Stale work.** For each stale item, `board claims <ID>`: a live claim means a session is on it; none means the session ended without finishing. Suggest `/packet-dispatch resume <ID>`.
- **Drift.** Suggest `board sync` for missing items and `board reconcile` for closed ones.
- **Budget** (with `-Credits`). The figures are estimates, so say so. When this month's credits pass about three quarters of `budget.monthlyCredits`, or an L packet would not fit in what is left, say so, and recommend the cheaper next moves: merges first, then S and M packets on the critical path. Suggest calibrating `budget.creditsPerRun` against the billing AI usage report when the owner has one.

## Report

Lead with the verdict and the reason, then the moves, then the detail:

```markdown
**<Phase title>: <health>.** <one-sentence reason>

Next moves
1. Merge <PRs in order> (unblocks <packets>).
2. Decide <ID>: <question> (recommended: <option>).
3. Start <n> sessions: <IDs, P0 first>.
4. Do <human task> by <date>.

Progress: <done>% merged, <landed>% merged or ready (by size) · P0 <d>/<t> · waves W0 <d>/<t> …
Critical path left: <ID> → <ID> → … (weight <w>)
At risk: <late, due soon, stale, inversions>
```

Keep it short: the owner reads the first three lines. Don't invent numbers the script didn't give.

If asked to **post** it: on GitHub, comment on the phase epic (`gh issue comment <epic> --body-file <file>`; the epic is the `**Epic:**` line of `plan.md`); otherwise write it to `<paths.plans>/<phase>/progress.md` only when the owner asks for a file. Never change board state from this skill.
