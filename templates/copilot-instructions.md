<!-- packet-workflow:start -->
## Packet workflow

Planned work in this repository is built as **task packets**: units of work that agents build in parallel, one pull request each.

- **Plans and packets** live in the plans directory (`paths.plans`, `docs/plan` by default): `<phase>/plan.md` and `<phase>/packets/<ID>.md`. A packet file is the source of truth for its scope: goal, owned paths, shared touchpoints, dependencies, acceptance criteria, tests and review lenses. The board item is generated from it and holds its status.
- **Configuration** is `.github/packet-workflow.json`; its `guardrails` bind every agent.
- **Skills:** `/packet-plan` (plan to packets), `/packet-board` (populate and read the board), `/packet-dispatch` (run a packet), `/packet-review` (review panel), `/packet-progress` (where a phase stands). **Agents:** `packet-dispatcher` runs a packet; it starts `packet-implementer` and the `packet-reviewer-*` tiers as subagents.
- **Agents never merge** pull requests, approve them, push to the default branch, force-push, or start or re-run CI. The owner merges.
- **One dispatcher per checkout.** Parallel packets run in separate sessions, each in its own git worktree.
- **An implementer edits only its packet's owned paths**, plus the shared touchpoints the packet lists, with the one edit each allows. Anything else is a question for the owner, not a change.
- Each packet records its open decisions in its own decision record, so parallel PRs never edit one shared file.
<!-- packet-workflow:end -->
