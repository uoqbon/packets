# Lens: tests

**Question:** would these tests go red if the change were wrong, and will they stay green for the right reasons in CI?

## Check

- Mutation thinking: for each acceptance criterion, name the test that proves it, then the smallest code change that should fail it (flip a comparison, drop a branch, skip a check). Would the test catch it?
- Determinism: time comes from an injected clock, randomness is seeded, nothing sleeps for real time, nothing depends on the order of an unordered collection or on test execution order.
- Isolation: no test reaches a real external service or a shared environment; external calls go through fakes, stubs or recorded fixtures.
- Fixtures look like what the real source returns (shapes, encodings, missing values); synthetic fixtures say so.
- Integration tests that need a database or container clean up after themselves and don't share state in a way that makes order matter.
- The repository's test conventions (framework, assertion style, naming, one test project per source project) are followed.
- Nothing weakened: no deleted, skipped or loosened assertion in existing tests without a stated reason.

## Leave to other lenses

Whether the production code is right (correctness and the specialists); this lens judges whether the tests would catch it if it weren't.

## Severity

- **blocking**: an acceptance criterion has no test that would fail on a plausible regression; a test depends on wall-clock time, the network or another test.
- **should-fix**: a weak assertion where a value is known, a missing edge-case test for behaviour the packet calls out.
