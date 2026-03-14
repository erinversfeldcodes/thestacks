# Issue #029: Bookshelf Page Aesthetic

## Summary
Implement the full visual aesthetic for all bookshelf pages (Library, AntiLibrary, WishList, Reading Pile) as described in user stories US-1.2.1 through US-1.2.5 — wallpapers, shelving materials, lighting effects, shelf labels, and inter-shelf transitions.

## User Stories
- US-1.2.1 Browse the Library Shelf
- US-1.2.2 Browse the AntiLibrary Shelf
- US-1.2.3 Browse the WishList Shelf
- US-1.2.4 Browse the Reading Pile
- US-1.2.5 Shelf Navigation Transitions
- US-1.6.5 Empty Shelf States

## Goal
Each bookshelf page has its own distinct, immersive visual identity as described in the user stories. Navigating between shelves feels physical and spatial. Empty states are inviting rather than blank. The overall experience reinforces the metaphor of moving through rooms in a personal library.

## Technical Requirements
- **Library:** Deep green damask wallpaper, dark walnut panelling, warm lamplight, brass shelf label
- **AntiLibrary:** Cream botanical wallpaper, lighter oak shelving, afternoon sunlight
- **WishList:** Watercolour floral wallpaper, soft blue-grey walls, morning light
- **Reading Pile:** Not a shelf — side table, armchair, worn rug, intimate reading nook
- **Transitions:** Horizontal slide between adjacent shelves (300–500ms), fade through darkness for room transitions (Reading Pile)
- **Empty states:** Per-shelf messaging and visual treatment as described in US-1.6.5
- All implemented in Elm, consistent with existing SPA architecture
- CSS-based textures and effects where possible; minimal image assets
- Mobile responsive — graceful degradation of visual effects on smaller screens
- No `unsafe-eval` in CSP

## Definition of Done
- [ ] Library page visual aesthetic implemented per US-1.2.1
- [ ] AntiLibrary page visual aesthetic implemented per US-1.2.2
- [ ] WishList page visual aesthetic implemented per US-1.2.3
- [ ] Reading Pile visual aesthetic implemented per US-1.2.4
- [ ] Shelf navigation transitions implemented per US-1.2.5
- [ ] Empty shelf states implemented per US-1.6.5
- [ ] Mobile responsive
- [ ] Tests written and passing
- [ ] Standards compliance verified

## Dependencies
- Issue #002 (Elm MVP frontend — base page structure must exist)

## Agent Assignment
elm-agent

## Progress Notes
[Updated by agents during execution.]
