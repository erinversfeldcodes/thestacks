# Issue #096: Remove Listing has_many :transactions Association

## Summary
`Stacks.Marketplace.Listing` declares `has_many :transactions, Transaction` but per ADR 013 transactions are deferred. This creates coupling to a feature that doesn't exist.

## Goal
Remove the unused association to align the schema with the classifieds-only scope.

## Scope Check
- 2 lines removed (association + alias)
- ~2 min

## Technical Requirements
- Remove `has_many :transactions, Transaction` from `listing.ex`
- Remove the `Transaction` alias if no longer needed
- Verify no code references `listing.transactions`

## Definition of Done
- [ ] Association removed
- [ ] All tests pass
- [ ] `just verify` passes

## Priority
P1 — fix before Wave E

## Agent Assignment
elixir-agent
