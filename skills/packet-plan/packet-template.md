# PKT-00 · Imperative title, at most 60 characters

- **Packet:** PKT-00 · **Priority:** P0 · **Size:** M · **Wave:** W1 · **Workstream:** Name · **Target:** 2026-11-02
- **Depends on:** none
- **Review lenses:** correctness, tests
- **Locks:** none
- **Initial status:** Ready

## Goal

One paragraph: the outcome this packet delivers, what uses it, and how it moves the phase toward its exit.

## Spec

Pointers, not copies: the plan or spec sections, ADRs or tickets this packet implements.

## In scope

- A concrete deliverable, named the way the code will name it.

## Out of scope

- Something a reader might expect here, and the packet that does it (PKT-07).

## Owns

- `src/Feature/**`
- `tests/Feature.Tests/**`
- `docs/decisions/phase-slug/PKT-00.md`

## Shared touchpoints

- `src/App/Program.cs`: one `AddFeature()` registration line.

## Consumes

- `IClock` from PKT-01 (`src/Core/Time/IClock.cs`).

## Provides

- `IFeatureService` (`src/Feature/IFeatureService.cs`): the surface later packets call.

## Acceptance criteria

- [ ] An observable, testable statement, with the numbers that matter (inputs, limits, status codes).

## Tests to run

- `dotnet test --project tests/Feature.Tests`

## Decision record

`docs/decisions/phase-slug/PKT-00.md`

## Dispatcher notes

What the dispatcher must know that the sections above don't say: a fake or fixture to use, an order of work, a stop condition, a reason this packet may not be split.
