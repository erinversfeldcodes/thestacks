# Issue #058b: Elm — Keyboard Navigation

## Summary
Implement full keyboard navigation: Tab between elements, arrow keys within shelves, Enter to open, Escape to close, focus management.

## User Stories
US-19.1.2 (keyboard navigation)

## Goal
Keyboard-only users can browse shelves, open book details, and dismiss overlays without a mouse.

## Technical Requirements
- Tab moves focus: nav → shelf content → individual spines
- Arrow keys within shelf grid: left/right in row, up/down between rows
- Enter on focused spine opens overlay
- Escape closes overlay, returns focus to triggering spine
- Tab within overlay moves between interactive elements
- Skip link: hidden "Skip to main content" before navigation
- Visible focus indicators (warm amber outline)
- Focus trap within open overlays

## Scope Check
- Modify Main.elm (keyboard subscriptions)
- Modify Components.Spine (tabindex, focus management)
- Modify Page.BookDetail (focus trap)
- Create focus management helpers
- ~200 LOC

## Dependencies
#057a (overlay), #058a (ARIA labels)

## Definition of Done
- [ ] Tab, arrows, Enter, Escape all work as specified
- [ ] Focus returns to triggering element on overlay close
- [ ] Skip link present and functional
- [ ] Focus indicators styled
- [ ] `elm-format --validate src/` passes

## Agent Assignment
elm-agent
