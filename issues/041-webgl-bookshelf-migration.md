# Issue #041: Migrate Bookshelf from CSS 3D to elm-3d-scene (WebGL)

## Status: SUPERSEDED

The WebGL approach was implemented through Phase 4 but failed to produce visual quality comparable to the pre-rendered photorealistic backdrops. The elm-3d-scene flat-colored quads could not match the cinematic aesthetic. Additionally, Brave's fingerprinting protection blocks `preserve-3d` which was the original motivation.

**Replaced by**: Pre-rendered photorealistic library backdrop + Brave-safe CSS 2D pull-out animation. No WebGL.

### What was done instead:
- Removed all Scene modules (Coordinates, World, BookMesh, Textures, Shelf, Room, Picking)
- Removed elm-3d-scene and 10 related packages from elm.json
- Removed DevWebGL route, `?webgl=1` feature flag
- Replaced `preserve-3d` + 3D keyframe animation with 2D CSS hover (translate, skewY, scaleX)
- Book cover/top faces start collapsed, expand on hover with staggered CSS transitions
- Added pre-rendered backdrop image per bookshelf type
- Added atmospheric overlays (vignette, light leak, dust motes) via CSS mix-blend-mode
- Added `prefers-reduced-motion` support and keyboard focus indicators
- Removed `blob:` from CSP (no longer needed)
- Tightened security headers

### Original Summary (for reference)
Replace the CSS 3D bookshelf rendering (`transform-style: preserve-3d`, `perspective`, `@keyframes`) with elm-3d-scene (WebGL). CSS 3D breaks in Brave with Shields up due to fingerprinting protection suppressing `preserve-3d`. WebGL renders consistently across all browsers and enables future cinematic features (camera dolly, room transitions, PBR materials).

## User Stories
- US-1.3 (Spine Rendering) — book spines render with correct dimensions, textures, and hover interaction
- US-1.2 (Browse Shelves) — user can browse books on shelves, click to view details

## Dependencies
- None

## Agent Assignment
- **elm-agent** (completed)
- **Reviewer**: elm-reviewer (completed — APPROVED)
- **Principal Engineer**: reviewed (P0-P3 findings all addressed)
