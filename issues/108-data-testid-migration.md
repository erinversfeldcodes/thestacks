# Issue #108: E2E data-testid Migration

## Summary
Replace CSS class selectors in Playwright E2E tests with `data-testid` attributes on key interactive elements. Decouples tests from styling so CSS refactors don't break the test suite.

## Goal
E2E tests should be resilient to CSS class renames, theme changes, and component restructuring. Tests select elements by intent (`data-testid="book-overlay"`) not by implementation (`.book-overlay__close`).

## Scope Check
- Add `data-testid` attributes to ~30-40 key Elm elements
- Update ~15 E2E test files to use `page.getByTestId()` instead of `.locator(".class")`
- ~200 LOC Elm + ~200 LOC test changes

## Technical Requirements

### Phase 1: High-value elements (most frequently breaking)
- Book detail overlay: `data-testid="book-overlay"`, `data-testid="book-overlay-close"`
- Settings hub: `data-testid="settings-hub"`, `data-testid="settings-sidebar"`
- Upload steps: `data-testid="upload-verify"`, `data-testid="upload-shelf-picker"`, `data-testid="upload-complete"`
- User menu: `data-testid="user-menu"`, `data-testid="user-menu-dropdown"`
- Cost page: `data-testid="costs-content"`, `data-testid="costs-category-card"`

### Phase 2: Interactive elements
- Shelf mover: `data-testid="shelf-mover-move-btn"`
- Format picker buttons
- Navigation links
- Filter/sort controls

### Elm helper
Create a `testId : String -> Html.Attribute msg` helper:
```elm
testId id = Html.Attributes.attribute "data-testid" id
```

### E2E migration
Replace `page.locator(".css-class")` with `page.getByTestId("semantic-name")` for migrated elements. Keep CSS class selectors for elements not yet migrated.

## Definition of Done
- [ ] `data-testid` attributes on all high-value elements
- [ ] E2E tests updated to use `getByTestId` where available
- [ ] No CSS class selectors for elements that have `data-testid`
- [ ] All 142 E2E tests pass
- [ ] `elm-format` and `elm-review` clean

## Agent Assignment
elm-agent + e2e updates
