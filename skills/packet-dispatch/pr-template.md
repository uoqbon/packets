<output of `board ref <ID>`: Closes #<n> | Fixes AB#<id>><stacked: · Stacked on #<dependency PR>; merge that first>

**Packet** [<ID>](<board item URL>) · **Plan** `<phase plan path>`

## Summary

<what this packet adds, 2-4 lines>

## Provides

<the public surface later packets build on: types, endpoints, components, commands>

## Acceptance criteria

- [x] <criterion>: <test name or command> ✅
- [ ] <criterion not met>: <why, and what the owner should decide>

## Tests run

| Command | Result |
| --- | --- |
| `<packet test command>` | <n> passed |
| `<commands.ci>` | passed |

## Scope

`check-scope.ps1`: inside the packet's paths. Shared touchpoints edited: <path: the edit, or none>.

## Deviations from the packet

<none, or each one with why>

## Decisions

`<decision record path>`

## Review plan

Tier <n> <name> (floor from `review-scope.ps1`: <reasons>)<; raised to … because …>. Round 1 lenses: <list>.
