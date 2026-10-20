# Lens: performance

**Question:** does the change stay within the latency, throughput and resource budgets the plan sets, at the data sizes it will meet?

## Check

- Hot paths: no work repeated per item that could be done once; no quadratic loops over inputs that grow; no synchronous I/O on request threads.
- Data access: queries bounded and indexed; results paged; caches have a size limit and an invalidation rule.
- Memory: large inputs are streamed, not loaded whole; no unbounded collections or event-handler leaks.
- Network: calls batched where the API allows; payloads no bigger than needed; compression where it helps.
- Measurement: a claim of "fast enough" is backed by a benchmark, a load test or numbers from the plan's budget.

## Leave to other lenses

Query correctness and schema (data), races (concurrency).

## Severity

- **blocking**: a reachable path that breaks a stated budget by an order of magnitude, or grows without bound with input size.
- **should-fix**: an avoidable repeated computation or allocation on a warm path, a missing page limit on a list that will grow.
