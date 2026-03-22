# Issue #058a: Elm — ARIA Labels

## Summary
Add descriptive ARIA labels to all interactive and visual elements across the application.

## User Stories
US-19.1.1 (ARIA labels)

## Goal
Screen reader users can navigate the platform meaningfully. Every interactive element has a descriptive label.

## Technical Requirements
- `Components.Spine`: `aria-label="Book: [Title] by [Author], [Pages] pages, [wear state]"`
- Bookshelf containers: `role="list"`, `aria-label="[Shelf Name] — N books"`
- Book detail overlay: `role="dialog"`, `aria-label="Book details: [Title]"` (from #057a)
- Upload progress: `aria-live="polite"` announcing states
- User menu: `aria-label="User menu"` (from #057c)
- Navigation items: descriptive labels
- Wear state in label: "(well-loved, read 3 times)"

## Scope Check
- Modify ~8 existing modules
- ~100 LOC of attribute additions

## Dependencies
#057a (overlay must exist for dialog role)

## Definition of Done
- [ ] All spines have descriptive aria-labels
- [ ] Bookshelf containers use role="list"
- [ ] Upload has aria-live regions
- [ ] All navigation items labelled
- [ ] `elm-format --validate src/` passes

## Agent Assignment
elm-agent
