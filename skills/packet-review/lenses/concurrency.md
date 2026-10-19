# Lens: concurrency

**Question:** does the code stay correct when things happen at the same time, and shut down cleanly?

## Check

- Shared mutable state: every field touched from more than one thread, request or task is protected (lock, immutable snapshot, single writer, concurrent collection), and compound check-then-act sequences are atomic.
- Async: no sync-over-async or fire-and-forget without error handling; cancellation tokens flow through; timeouts on external calls.
- Ordering: events, messages and retries that can arrive twice or out of order are handled (idempotency keys, sequence numbers).
- Background work: workers, pollers and timers stop on shutdown, don't overlap themselves, and survive a failing iteration.
- Single-flight: expensive or rate-limited operations (token refresh, cache fill) run once for concurrent callers.
- Tests: concurrency claims have a test that runs the racing paths in parallel many times, deterministically where possible.

## Leave to other lenses

Database-level races (data), logic errors on one thread (correctness).

## Severity

- **blocking**: a reachable race that corrupts state, loses or duplicates work, deadlocks, or leaks a background task past shutdown.
- **should-fix**: a missing timeout or cancellation on a non-critical path; a race with a benign outcome that still deserves a guard.
