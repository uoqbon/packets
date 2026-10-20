# Lens: architecture

**Question:** does the change fit the codebase's layering and the packet's boundaries, so the packets being built in parallel still fit together?

## Check

- **Ownership:** every changed path is in the packet's Owns or a listed shared touchpoint, and touchpoint edits are the small kind the plan allows (one registration line, one project or package line). List any path outside both. `check-scope.ps1` gives the list.
- **Contracts:** what the PR says it Provides matches the public surface in the diff, and matches what dependent packets expect (read their packet files' Consumes). A renamed or reshaped shared type is flagged with its call sites.
- Layering rules the repository states (instructions, ADRs, architecture docs): dependencies point the allowed way; core code has no I/O; UI talks to the server only through its API.
- External services sit behind interfaces with fakes; nothing new calls them directly from domain code or UI.
- No lock-held resource (a migration, a schema, a generated client) is touched unless the packet holds the lock.
- New dependencies (packages, services) are justified and pinned the way the repository pins them.
- A decision record exists for the packet and covers each choice the plan left open.

## Leave to other lenses

Logic errors (correctness), threading (concurrency), test quality (tests).

## Severity

- **blocking**: a layering rule is broken, a path outside Owns changes something another packet owns, or a provided contract doesn't match what a dependent packet needs.
- **should-fix**: a missing decision record entry, an avoidable new dependency, a touchpoint edit bigger than allowed but harmless.
