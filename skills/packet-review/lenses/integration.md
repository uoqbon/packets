# Lens: integration

**Question:** does the code handle the real shapes and failure modes of what it talks to: external APIs, files, queues and other services?

## Check

- Parsers accept what the source really sends: optional and missing fields, extra fields, encodings, number and date formats, pagination, empty results. Fixtures are recorded from the real source or say they are synthetic.
- Failure modes: timeouts, retries with backoff and a cap, rate limits (429 and Retry-After), 4xx versus 5xx handled differently, partial responses, circuit breaking where calls are frequent.
- Contracts with other services are versioned or tolerant; a change in their response can't crash this code.
- Fakes used in tests behave like the real service on the paths tested (status codes, ordering, errors).
- File formats: headers, delimiters and quoting, byte-order marks, very large inputs, and the error a user sees for a malformed file.

## Leave to other lenses

Authorization of inbound calls (security), storage (data).

## Severity

- **blocking**: a real response shape or failure crashes the code or produces wrong data; a retry loop without a cap.
- **should-fix**: a missing timeout, a poor error message for a malformed input, a fixture that differs from the real source in a way tests don't exercise yet.
