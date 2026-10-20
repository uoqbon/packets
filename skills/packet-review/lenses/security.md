# Lens: security

**Question:** can anyone see or change data that isn't theirs, can a secret leak, and can untrusted input steer the system?

## Check

- **AuthN/AuthZ:** every new endpoint, page, message handler and job checks who is calling and that they may act on this resource (tenant, owner, role); tests cover both "not signed in" and "signed in as someone else".
- **Secrets:** no key, token, password or connection string in code, config committed to the repo, logs, exception messages, telemetry or anything sent to a browser. New secrets are read from the platform's secret store and documented for the owner.
- **Input:** validation and size limits server-side before parsing; parameterized queries; no string-built shell commands, paths or queries from user input; uploads checked for type and size; output encoded for its context (HTML, CSV formulas, logs).
- **Web:** state-changing requests are protected against CSRF; CORS is no wider than needed; cookies carry the right flags.
- **Tokens:** refresh is single-flight, the newest refresh token is kept, revoked or expired tokens fail closed.
- **LLM input:** untrusted text reaches a model only as delimited data with an instruction not to follow it; model output is validated before it drives an action or is rendered.
- **Supply chain:** new packages come from the expected registry, at pinned versions.

## Leave to other lenses

General logic (correctness), infrastructure layout (ops).

## Severity

- **blocking**: cross-user or cross-tenant access, a secret exposed anywhere, a missing authorization check, injection, model output used unvalidated.
- **should-fix**: defence-in-depth gaps (a missing size cap on a non-critical path, overly detailed error text).
