# Lens: correctness

**Question:** does the changed code do what the packet's acceptance criteria and the plan say, for every input it can receive?

## Check

- Each acceptance criterion: is it met by the code, not just claimed in the PR body? Name the line that meets it.
- Boundaries: empty and single-element collections, nulls and missing optional fields, zero, negative and maximum values, the first and last item, time zones and date edges, unusual but legal configurations.
- Error paths: what the caller sees when a dependency fails (network, storage, an external API); exceptions swallowed, or rethrown without context; partial work left behind.
- Every call site of a changed public signature (search for it), including other packets' code already on the default branch.
- Claims in new comments, docstrings, decision records and the PR body are true of the code beside them.
- Docs-only changes: every command, setting, route and path named exists at the head commit.

## Leave to other lenses

Thread safety (concurrency), authorization (security), schema and query behaviour (data), test quality (tests), layering (architecture), visual and interaction quality (ux).

## Severity

- **blocking**: an acceptance criterion isn't met, or a reachable input gives a wrong result, corrupts state or throws unhandled.
- **should-fix**: a real but narrow defect (a misleading error message, an edge case outside the packet's stated use).
