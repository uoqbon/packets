---
name: packet-plan
description: "Cut an implementation plan into task packets that several coding agents can build in parallel without colliding. Each packet is one PR with owned paths, contracts, dependencies, testable acceptance criteria and review lenses. Writes the phase plan and one packet file per task, then validates them. Use when asked to break a plan, spec, epic or phase into packets, tasks or work items for agents, or to check or repair existing packet files."
argument-hint: "<path to the implementation plan> [phase name]"
---

# Plan to packets

You turn an implementation plan into a **phase**: a short plan file that indexes the work, and one **packet file** per unit of work. A packet is what one implementer agent builds in one pull request, while other agents build other packets at the same time. Packets are the contract between everyone downstream: the board is generated from them, the dispatcher briefs from them, the reviewers judge against them.

Good packets make parallel work safe. Bad ones make agents edit the same files, wait on each other, or build something nobody can review.

## Before you start

- Read `.github/packet-workflow.json`. It gives `packetPrefix` (IDs are `<prefix>-<n>`), `humanPrefix` (human tasks), `paths.plans` and `paths.decisions`, and the configured `locks`. No config: stop and point the owner at the kit's `install.ps1`.
- Read the plan you were given, then the repository: its layout, build and test commands, CI workflow, the repository instructions (`.github/copilot-instructions.md`, `AGENTS.md`), ADRs, and the code the plan changes. You can't draw ownership lines in code you haven't looked at.
- Ask the owner only what neither the plan nor the code answers: the deadline, who merges, what sits behind the cut line, which external approvals or secrets are pending. Ask once, together.

## What you write

```
<paths.plans>/<phase>/plan.md            from plan-template.md
<paths.plans>/<phase>/packets/<ID>.md    from packet-template.md (or human-task-template.md)
```

`<phase>` is a short kebab-case slug (`phase-1-checkout`). The file name is the ID. Templates: [packet](./packet-template.md), [human task](./human-task-template.md), [plan](./plan-template.md). Keep the heading line (`# <ID> · <title>`), the bold metadata lines and the `##` section names exactly: the scripts parse them.

## Procedure

1. **Inventory.** List the deliverables, the **contracts** (shared types, interfaces, schemas, API shapes, events, config keys), the **external dependencies** (APIs, credentials, approvals), the **exclusive resources** (database migrations, a lockfile to regenerate, a generated client, a global config file) and the **shared files** every feature touches (startup registration, routing, navigation, package manifests, solution files).
2. **Find the seams.** Put the contracts and the fakes for external services in the first packet(s), so everything after can code against them in parallel. Then cut the rest along directories that one packet can own outright: vertical slices (one feature end to end inside its own folders) beat horizontal layers (all models, then all services), which collide on every file.
3. **Draft the packets** under the rules below. Number them in dependency order.
4. **Write the files**, one per packet and one per human task.
5. **Validate** and fix until there are no errors:

   ```bash
   pwsh -File .github/skills/packet-plan/scripts/validate-packets.ps1 -Phase <phase>
   ```

   ERRORs block the board: overlapping ownership between packets that can run at the same time, a shared lock without an order, a cycle, a missing dependency, a malformed file. Fix each WARN too, or say in the plan why it stands. The summary gives the waves, the packets most others depend on and the critical path; use them in the plan.
6. **Write the plan file**: goal and constraints, milestones, the packet index table, a Mermaid dependency graph, the critical path, the schedule by wave, a `## Shared touchpoints` section with its table (the validator checks packets against it, and warns when packets use touchpoints but the plan has no such section), locks, and the cut line.
7. **Hand off.** Tell the owner: the number of packets per priority and wave, the critical path, what must merge first, the human tasks and when they're due, and any judgement call you made. Recommend reviewing the phase as a pull request before the board is populated (`/packet-board sync`), because every later step trusts these files.

## Rules for a good packet

**Size.** One packet is one PR that one implementer finishes in one session and that a review panel can clear in at most three rounds. S is about 150 changed lines of logic, M about 400, L about 1,000. Nothing bigger: split it. Two to eight acceptance criteria. A packet with more is two packets.

**Owns.** Backticked globs, one per bullet, relative to the repo root: `src/Billing/**`, `tests/Billing.Tests/**`. Include the packet's tests and its decision record. Use `!glob` to carve out a sub-folder another packet owns. Two packets that can run at the same time (neither depends on the other, directly or not) never own the same path. When two need the same file, one owns it and the other depends on it, or the file becomes a shared touchpoint.

**Shared touchpoints.** Files many packets must touch (startup, DI registration, routing, nav, package manifests, solution files). List each in the plan's touchpoints table with the one kind of edit allowed: "one `AddX()` line", "one package version line". A packet lists the touchpoints it uses, with the edit. Anything bigger than that edit belongs in the packet's own files (an extension method, a module), with only the one-line hook in the shared file. Conflicts there are resolved by merging the default branch, never by rebasing.

**Contracts first.** The packet that lands the shared types, interfaces and fakes comes first and stays small, because everything waits on it. Its **Provides** names every type and signature exactly; dependent packets name the same things under **Consumes**. Where the plan leaves a name open, decide it here so parallel packets agree.

**Dependencies.** Only real ones: "needs code from X merged". Keep the graph wide and shallow, so many packets can run at once; a deep chain is a schedule risk. No cycles. A human task can be a dependency (an approval, a key).

**Locks.** An exclusive resource (migrations, a regenerated lockfile, a generated client, one shared schema) is a lock in the config. A packet that touches it lists the lock under **Locks**, and owns its paths. Packets holding the same lock must be ordered by dependencies. Prefer one packet per lock per phase (for example, one packet adds every table the phase needs).

**Acceptance criteria.** Observable and testable, with the numbers that matter: "50 concurrent requests for distinct items create 50 rows and no duplicates", not "handles concurrency". Each one maps to an automated test, or for non-code packets to a command and its output. Write them as `- [ ] …`.

**Tests to run.** The exact commands, scoped to the packet (`dotnet test --project tests/Billing.Tests`, `npm test -- billing`). Tests run offline and deterministically: external services behind fakes or recorded fixtures, time from an injected clock.

**Review lenses.** Pick from the catalog by risk surface; `correctness` always, `tests` for any code:

| Lens | When the packet… |
| --- | --- |
| security | handles auth, user input, uploads, secrets, tokens, or renders untrusted content |
| data | changes schema, persistence, migrations or imports |
| concurrency | has shared state, background workers, pollers, queues or parallel requests |
| integration | parses or calls an external API, file format or another service |
| architecture | lands or changes contracts, layering, or project structure |
| ops | touches CI, infrastructure, deployment, configuration or runbooks |
| ux | changes what users see or click |
| ai | calls a language model |
| performance | sits on a hot path or has a stated latency or size budget |

A project can add its own lenses (for domain rules) as `<paths.lenses>/<name>.md`.

**Priority, waves, targets.** P0: the phase fails without it. P1: planned. P2: behind the cut line, so `**Initial status:** Backlog` until the owner promotes it. P3: nice to have. Wave W0 is the foundation; a packet's wave is one more than its latest dependency's. Its **Target** (yyyy-MM-dd) is the date it should reach Ready to merge.

**Human tasks.** Approvals, secrets, purchases, production checks and judgement calls on real data are human tasks (`**Human task:** H-1`), never folded into a packet. Agents don't do them; packets can wait on them.

**Out of scope** names who does each excluded thing ("the UI: PKT-14"). **Dispatcher notes** say what the dispatcher must know: a fake to use, an order of work, a stop condition.

**Dark launch.** When every merge to the default branch deploys, new features stay unreachable (unregistered route, feature flag) until a wiring packet switches them on. Say which packet does.

## Anti-patterns

| Pattern | Why it fails | Instead |
| --- | --- | --- |
| Layer-cake packets (all models, then all services, then all UI) | every packet edits every feature's files | vertical slices with owned folders |
| "Misc" or "glue" packet late in the plan | it owns everything and conflicts with everything | put each hook in the packet that needs it, through a touchpoint |
| Two packets editing one config or registration file freely | merge conflicts on every PR | a touchpoints table with one allowed edit each |
| Hidden dependency through a shared file | B breaks when A merges | make B depend on A, or give the file one owner |
| "Tests later" packet | code merges unproven; reviewers can't judge | tests live in the packet that writes the code |
| Vague criteria ("works well", "is fast") | nothing to test, nothing to review against | numbers and observable outcomes |
| A packet waiting on an approval nobody owns | it blocks silently | a human task with a target date, as a dependency |

## Repairing existing packets

Asked to check or fix packets: run the validator first, fix what it reports, then read each packet against the rules above (size, criteria, lenses, touchpoints). Keep IDs stable once a packet is on the board; add new IDs rather than renumbering. If a packet is already In progress or later, don't change its scope without the owner: say what you'd change and why.
