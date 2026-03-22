# Issue #089: Pre-filter Books for LLM Association

## Summary
Replace the 200-book limit in PostBookAssociationWorker with text search pre-filtering. Match book titles/authors against the post body before sending to the LLM.

## Goal
The current approach loads up to 200 books and sends them all to the LLM. As the catalogue grows, this wastes tokens and may exceed context limits. Pre-filtering to only books whose titles or authors appear in the post body is more efficient and more accurate.

## Scope Check
- Modify PostBookAssociationWorker
- ~50 LOC

## Technical Requirements
- Extract words/phrases from post body
- Query books where title or author name matches any extracted term (use `title_tsv` for full-text search)
- Fall back to the 200-book limit if pre-filtering returns too few candidates
- Consider: should we also check ISBN mentions in the post body?

## Definition of Done
- [ ] Worker pre-filters books by text match
- [ ] Falls back to limit-based approach when no matches
- [ ] Tests cover both paths
- [ ] `just verify` passes

## Agent Assignment
elixir-agent
