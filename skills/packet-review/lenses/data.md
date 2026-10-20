# Lens: data

**Question:** does the change keep stored data correct, recoverable and cheap to query, today and after the next migration?

## Check

- Migrations: only the packet holding the migration lock adds one; it is reversible or says why not; it runs on existing data (defaults for new non-null columns, backfills, large-table locks).
- Schema matches the model: keys, indexes for the new queries, constraints (unique, foreign keys) that enforce the invariants the code assumes.
- Writes: transactions where several rows must change together; idempotent imports and retries (a second run doesn't duplicate); optimistic concurrency where two writers can race.
- Reads: no N+1 queries in loops; paging on unbounded lists; no full-table scans on hot paths.
- Retention and privacy: personal data isn't copied to new places without need; deletes cascade or are handled.
- Cost and limits of the data store (request units, connection limits, storage tiers) the plan mentions.

## Leave to other lenses

Business logic (correctness), concurrency outside the database (concurrency).

## Severity

- **blocking**: data loss or corruption, a migration that fails on existing data, a race that duplicates or drops writes, a missing transaction around a multi-row invariant.
- **should-fix**: a missing index on a query the packet adds, a non-reversible migration without a stated reason.
