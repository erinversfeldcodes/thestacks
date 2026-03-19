# Issue #041: WebGL Bookshelf Migration (elm-3d-scene)

## Summary
Migrate the bookshelf from CSS 3D transforms to elm-3d-scene (WebGL) to fix the Brave browser fingerprinting bug that suppresses `transform-style: preserve-3d`, and deliver a cinematic dark-academic aesthetic with real 3D book meshes, PBR textures, and atmospheric overlays.

## Status: CLOSED — COMPLETE (merged in PR #68, feat/assorted-UI)

## What Was Delivered

All phases (0–4) completed and merged:
- **Phase 0**: elm-3d-scene installed, `/dev/webgl` dev route, `Scene.Coordinates`, `Scene.World`
- **Phase 1**: `Scene.BookMesh` (3D quads), `Scene.Textures` (async loading, 26 textures), 7 unit tests
- **Phase 1.5**: 22 cinematic assets generated via Replicate Flux Dev (normal maps, fallback covers, atmospheric overlays, environment art)
- **Phase 2**: `Scene.Shelf`, `Scene.Room` (textured wallpaper, bookcase, persian rug, warm lighting), `?webgl=1` feature flag
- **Phase 3 / 3.5**: `Scene.Picking` (raycasting), canvas mouse event wiring, hover animation (book pulls forward), click-to-BookDetail
- **Phase 4**: Atmospheric compositing — vignette, light leak, dust motes via CSS blend modes

**Feature flag**: `?webgl=1` — defaults to false in production; zero impact unless enabled.

See `plans/041-webgl-bookshelf-migration-plan.md` for full phase details and file manifest.

## DoD
- [x] WebGL bookshelf renders in Brave with Shields up (no CSS 3D dependency)
- [x] 3D book meshes with texture loading
- [x] Hover and click interaction via raycasting
- [x] Atmospheric overlays composited
- [x] Feature-flagged behind `?webgl=1`
- [x] CSP updated (`blob:` in `img-src`)
- [x] 258 Elm tests passing
- [x] elm-review clean
- [x] Merged PR #68

## Progress Notes
Completed 2026-03-17 across feat/assorted-UI branch. Closed 2026-03-19.
