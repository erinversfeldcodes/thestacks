# Issue #097: Update ADR 002 Queue Configuration

## Summary
ADR 002 documents `vision: 2` concurrency but actual config has `vision: 5`. The ADR also lists planned queues (`review_scrape`, `author_scrape`, `source_discovery`, `geographic_discovery`) that were never created — those workers run on `default`.

## Goal
Update ADR 002 to reflect actual queue configuration.

## Scope Check
- 1 file, ~20 lines
- Documentation only

## Definition of Done
- [ ] ADR 002 queue table matches config.exs
- [ ] Planned-but-not-created queues noted as "merged into default"

## Priority
P2 — fix during Wave E

## Agent Assignment
Any
