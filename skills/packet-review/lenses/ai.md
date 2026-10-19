# Lens: ai

**Question:** does the code use a language model safely, predictably and within budget, and does the product still work when the model doesn't?

## Check

- Output is validated against a schema or an allow-list before it is used or shown; invalid output has a defined fallback.
- Untrusted text (user input, web pages, documents, tool results) reaches the model only as delimited data with an instruction not to follow it.
- Timeouts, retries with a cap, and a fallback path when the model is slow, refuses or is unavailable.
- Cost: token limits on input and output, prompt caching where the prompt repeats, the cheapest model that does the job, usage logged.
- Prompts live in versioned files or constants, with tests or evals for the behaviours the packet promises.
- No secrets or unnecessary personal data in prompts or logs.

## Leave to other lenses

General input handling (security), the code around the call (correctness).

## Severity

- **blocking**: model output drives an action or is rendered without validation, untrusted text can instruct the model, or there is no fallback on a path the product needs.
- **should-fix**: a missing token cap, no caching on a repeated prompt, an untested prompt behaviour.
