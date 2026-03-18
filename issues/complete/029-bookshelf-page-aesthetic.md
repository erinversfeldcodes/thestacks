# Issue #029: Bookshelf Page Aesthetic

## Summary
Implement the full visual aesthetic for all bookshelf pages (Library, AntiLibrary, WishList, Reading Pile) as described in user stories US-1.2.1 through US-1.2.5 — wallpapers, shelving materials, lighting effects, shelf labels, and inter-shelf transitions. Build out a library/ package similar to https://github.com/petargyurov/virtual-bookshelf?tab=readme-ov-file but which is Elm-native. Use https://github.com/petargyurov/virtual-bookshelf?tab=readme-ov-file and its application on https://petargyurov.com/bookshelf/ as the baseline for the animations, cover and legibility of the book spine, but create more textures and stylings more in the vein of our own to apply.We want the books spines to look like a mix of cloth and leather bound. The bookshelves themselves should be individually styled as described in the technical requirements below, but the structure of the bookshelf should always look something like /Users/erinversfeld/thestacks/bookshelf.png. Generate the necessary artefacts to create all aesthetics. 

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
- **Library:** Deep green damask wallpaper, dark walnut shelving, warm lamplight, brass shelf label
- **AntiLibrary:** Cream botanical wallpaper, lighter oak shelving, afternoon sunlight, brass shelf label
- **WishList:** Watercolour floral wallpaper, soft blue-grey walls, rosewood shelving, morning light, brass shelf label
- **Reading Pile:** Not a shelf — side table, armchair, worn rug, intimate reading nook, similar to /Users/erinversfeld/thestacks/green-leather-armchair-with-books-front-wall_689970-1324.avif
- **Transitions:** Horizontal slide between adjacent shelves (300–500ms), fade through darkness for room transitions (Reading Pile). Navigation by clicking through shelf names on a navbar.
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
