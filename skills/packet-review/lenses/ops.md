# Lens: ops

**Question:** can this be built, deployed, configured, observed and rolled back safely, and does it keep agents away from production?

## Check

- CI and workflows: least-privilege permissions, pinned actions, secrets only where needed, no path that lets a branch or an agent deploy, publish or reach production.
- Infrastructure as code: names, regions and SKUs as the plan says; no secret in templates; changes are additive or say how they roll back.
- Configuration: new settings have defaults that are safe, are documented, and are validated at startup.
- Observability: errors are logged once with context and no secrets; new background work has health signals; metrics or traces where the plan asks.
- Release safety: a feature that isn't ready stays unreachable (flag, unregistered route) when the default branch deploys continuously; migrations and deploy order are compatible.
- Runbooks and docs: every command, setting and path they name exists and works.

## Leave to other lenses

Application logic (correctness), secrets in application code (security).

## Severity

- **blocking**: a way for an agent or a branch to reach production, a secret in CI logs or templates, a deploy that can't roll back, a workflow with write permissions it doesn't need.
- **should-fix**: a missing health signal or log context, an undocumented setting.
