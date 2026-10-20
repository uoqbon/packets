# Lens: ux

**Question:** can a user do the task quickly and without mistakes, on the devices and in the conditions the plan describes?

## Check

- The main task needs as few steps as possible; the primary action is obvious; destructive actions confirm or can be undone.
- State is visible: loading, empty, error and success states exist and say what to do next.
- Input: validation messages appear next to the field, keep what the user typed, and match the server's rules.
- Accessibility: keyboard reachable, visible focus, labels on controls, contrast, no information by colour alone, screen-reader names on icons.
- Layout holds at the narrowest supported width and with long text; no horizontal scroll on mobile.
- Copy is short, consistent with the rest of the product, and free of internal jargon.

## Leave to other lenses

Client-server contracts (architecture), authorization of what the page shows (security).

## Severity

- **blocking**: the main task can't be completed, data entered is lost, an action is irreversible without warning, or the page is unusable by keyboard.
- **should-fix**: a missing empty or error state, a confusing label, a contrast or focus problem on a secondary control.
