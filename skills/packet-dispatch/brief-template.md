`packet:brief base=<base sha> branch=<branch> mode=START`
**Implementation brief · <ID> <title>**

<details>
<summary>Brief for the implementer (base <short sha>, branch <branch>)</summary>

Packet file: `<packet path>` at `<base sha>` · Branch `<branch>` from `<base ref>`

## Your contract

- **Work in this checkout, on branch `<branch>`.** Don't switch branches, and don't touch other worktrees.
- **Stay inside the packet's paths:** the Owns list and the shared touchpoints below, with only the edit each touchpoint allows. If the work needs any other path, stop and report.
- **Don't change contracts other packets rely on** (the names under "You build on") beyond what this brief says. If one is wrong or missing, stop and report.
- **Locks:** <none | the locks this packet holds>. Don't touch a lock's paths unless this packet holds it.
- **Never:** push, open or merge a PR, force anything, start or re-run CI, run `gh` or post anything to GitHub or the board, or run any of: <guardrails.forbiddenCommands>. <guardrails.rules, one per line>
- **Don't edit** the workflow kit (`.github/skills/`, `.github/agents/`, `.github/hooks/`, `.github/packet-workflow.json`) or the packet files.
- **Conventions:** <the repository's language, framework, style and test conventions that apply here>.
- **Tests:** run the commands under "Tests to run". Tests stay offline and deterministic: fakes or fixtures for external services, an injected clock for time.
- **Commit** your work on this branch with clear messages. Write `<decision record path>` for every choice the packet left open.

## Goal

<from the packet, one paragraph>

## You build on (verified at the base)

<Exact namespaces, type names, signatures and file paths from merged code this packet consumes. Note where they differ from the packet's suggested names.>

## Patterns to copy

<Existing files that show how this repository does the same kind of thing.>

## Tasks

1. <ordered, concrete steps>

## Paths

- **Owns:** <from the packet>
- **Shared touchpoints (only the allowed edit):** <path: allowed edit>

## Acceptance criteria → tests

| Criterion | Test or command that proves it |
| --- | --- |
| <criterion> | <test name and project, or command> |

## Tests to run

<the packet's commands>

## Out of scope

<from the packet, with who does each part>

## Stop and report instead of guessing when

- the plan, the packet and the code disagree;
- you need a path outside your list, a lock you don't hold, or a contract change;
- an acceptance criterion can't be met as written;
- the build or tests fail for a reason outside this packet.

## Report back

1. **Summary**: what you built, in a few lines.
2. **Provides**: the public surface other packets will use (names and signatures).
3. **Acceptance criteria**: each with the test or command that proves it, and its result.
4. **Tests run**: the commands and their pass/fail counts.
5. **Deviations**: anything that differs from this brief, and why.
6. **Commits**: SHAs and subjects.
7. **Open questions**: or "none".

</details>
