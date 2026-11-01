<!-- packet-workflow:start -->
## Packet workflow (plan and board only)

Planned work in this repository is cut into **task packets**: units of work built one pull request each, by a person or a coding agent.

- **Plans and packets** live in the plans directory (`paths.plans`, `docs/plan` by default): `<phase>/plan.md` and `<phase>/packets/<ID>.md`. A packet file is the source of truth for its scope: goal, owned paths, shared touchpoints, dependencies, acceptance criteria, tests and review lenses. The board item is generated from it and holds its status.
- **Configuration** is `.github/packet-workflow.json`.
- **Skills:** `/packet-plan` (plan to packets), `/packet-board` (populate and read the board), `/packet-progress` (where a phase stands). This repository has no dispatcher, no review panel and no packet agents.
- **Agents never merge** pull requests, approve them, push to the default branch, force-push, or start or re-run CI. The owner merges.
- **Whoever builds a packet edits only its owned paths**, plus the shared touchpoints the packet lists, with the one edit each allows. Anything else is a question for the owner, not a change.
- Each packet records its open decisions in its own decision record, so parallel PRs never edit one shared file.
<!-- packet-workflow:end -->
