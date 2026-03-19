# Plan: Migrate Bookshelf from CSS 3D to elm-3d-scene (WebGL)
**Issue**: #041
**Created**: 2026-03-17
**Status**: SUPERSEDED — WebGL approach abandoned in favour of pre-rendered backdrops + Brave-safe CSS 2D animation. See issue #041 for details.

## Context

The CSS 3D bookshelf (`transform-style: preserve-3d`, `perspective`, `@keyframes`) breaks in Brave with Shields up — `preserve-3d` is suppressed by fingerprinting protection. The user wants a cinematic, game-like experience: camera dolly through a corridor into the library, interactive 3D books, smooth camera transitions. CSS 3D cannot deliver this. elm-3d-scene (WebGL) can.

**Decisions made:**
- Camera: cinematic rail — fixed angles per room, animated transitions
- Login: full 3D corridor (future phase)
- Scope for this branch: Phase 0–3 + asset pipeline — complete interactive bookshelf with feature flag
- Non-shelf pages: future phases
- Branch: `feat/assorted-UI`
- Asset pipeline: Replicate Flux Dev for cinematic textures, fallback covers, atmosphere

---

## Pre-Phase A: Worktree Path Isolation — COMPLETE

Added worktree-relative path rules to `docs/agents/orchestrator-agent.md`.

## Pre-Phase B: Principal Engineer Gate — COMPLETE

Added Phase 2F (PE Gate) to `docs/agents/orchestrator-agent.md`.

## Pre-Phase C: Agent Definitions & Issue Setup — COMPLETE

- Extended `docs/agents/elm-agent.md` with WebGL/elm-3d-scene section
- Extended `docs/agents/reviewers/elm-reviewer.md` with Axis 8a: WebGL review criteria
- Created `issues/041-webgl-bookshelf-migration.md`

---

## Phase 0: Foundation — COMPLETE

- Installed elm-3d-scene + 13 dependencies in `frontend/elm.json`
- Created `frontend/src/Scene/Coordinates.elm` — shared `WorldCoordinates` phantom type
- Created `frontend/src/Scene/World.elm` — test scene with book entity
- Wired `/dev/webgl` route in Route.elm + Main.elm (auth-gated)

**Files**: `frontend/elm.json`, `frontend/src/Scene/World.elm`, `frontend/src/Scene/Coordinates.elm`, `frontend/src/Navigation/Route.elm`, `frontend/src/Main.elm`

---

## Phase 1: Book Mesh — COMPLETE

- Created `frontend/src/Scene/BookMesh.elm` — 3D book entity (3 quads: spine, cover, top) with px-to-meters conversion
- Created `frontend/src/Scene/Textures.elm` — async texture loading with Dict cache, 26 textures
- Created `frontend/tests/Scene/BookMeshTest.elm` — 7 unit tests
- Exposed `colorIndex` and `textureData` from `Components.Spine`

**Files**: `frontend/src/Scene/BookMesh.elm`, `frontend/src/Scene/Textures.elm`, `frontend/tests/Scene/BookMeshTest.elm`, `frontend/src/Components/Spine.elm`

---

## Phase 1.5: Cinematic Asset Pipeline — COMPLETE

Generated 22 high-quality assets via Replicate Flux Dev for cinematic scene rendering.

### Assets Generated

| Category | Count | Files | Purpose |
|----------|-------|-------|---------|
| PBR Normal Maps | 6 | `normal-leather-{burgundy,green,navy}.png`, `normal-cloth-weave.png`, `normal-wood-walnut.png`, `normal-damask.png` | Future `Material.bumpyNonmetal` upgrade (Phase 7) |
| Fallback Book Covers | 8 | `cover-fallback-{01..08}.png` | Deterministic fallback when Google Books has no cover |
| Atmospheric Overlays | 3 | `overlay-light-leak.png`, `overlay-dust-motes.png`, `overlay-vignette.png` | Cinematic compositing over WebGL canvas |
| Environment Art | 3 | `ceiling-library.png`, `floor-hardwood.png`, `floor-persian-rug.png` | Room environment |
| Enhanced Wood | 2 | `wood-walnut-shelf-hq.png`, `wood-side-panel.png` | High-quality shelf/panel textures |

### Integration

- `Textures.elm` loads all 26 textures on init
- `Textures.fallbackCoverKey` deterministically assigns 1 of 8 covers by title hash
- `Room.elm` uses real wallpaper textures per shelf type, wood textures for panels/planks, persian rug floor
- `BookMesh` receives fallback cover texture from Room via `coverTexture` field
- Atmospheric overlays loaded but not yet composited (future: HTML overlay divs on canvas)

### Generation Script

`scripts/generate-textures.py` — idempotent, retry-on-429, Flux Dev quality mode. Manifest at `frontend/public/textures/manifest.json`.

**Files**: `scripts/generate-textures.py`, 22 PNGs in `frontend/public/textures/`, `frontend/public/textures/manifest.json`

---

## Phase 2: Shelf and Bookcase Scene — COMPLETE

- Created `frontend/src/Scene/Shelf.elm` — shelf row with textured plank, back panel, positioned books
- Created `frontend/src/Scene/Room.elm` — full room scene: textured wallpaper, bookcase, wood panels, persian rug floor, warm point light + overcast fill, per-shelf camera positions
- Added `useWebGL` flag + `textures` to `Page.Bookshelf.Model`
- `?webgl=1` URL param toggles between CSS 3D and WebGL rendering
- Feature flag defaults to `False` — zero production impact

**Files**: `frontend/src/Scene/Shelf.elm`, `frontend/src/Scene/Room.elm`, `frontend/src/Page/Bookshelf.elm`

---

## Phase 3: Interaction — MOSTLY COMPLETE

### Done
- Created `frontend/src/Scene/Picking.elm` — raycasting via `Camera3d.ray` + `Axis3d.intersectionWithRectangle`
- Added `hoveredBookId`, `hoverProgress`, `AnimationTick` to Bookshelf model/Msg
- `onAnimationFrameDelta` subscription only active when animation in progress
- Hover: book translates forward 0.05m with eased interpolation
- Click: `WebGLBookClicked` navigates to BookDetail via existing OutMsg pattern
- Accessibility: hidden `role="list"` HTML layer with keyboard-navigable buttons alongside canvas
- `Room.bookHitTargets` builds `Rectangle3d` hit targets from placements

### Remaining
- **Canvas mouse event wiring**: `pickBook` is implemented but not yet called — needs `Html.Events.on "mousemove"` with a custom decoder for mouse position relative to the canvas element. This requires either:
  - A custom event decoder using `offsetX`/`offsetY` from the mouse event (pure Elm, no port needed)
  - Or a thin port for canvas coordinate mapping
- **Hover trigger**: Wire `onMouseMove` on the canvas container → run `pickBook` → fire `WebGLBookHovered`
- **Click trigger via canvas**: Currently only the accessibility layer fires `WebGLBookClicked`. Need `onClick` on canvas → `pickBook` → navigate. The accessibility buttons already work for keyboard/screen reader users.

---

## CSP Update — COMPLETE

Added `blob:` to `img-src` in `apps/core/lib/stacks_web/plugs/security_headers.ex`.

---

## Phase 3.5: Canvas Mouse Events — COMPLETE

Wired mouse events on the WebGL canvas for hover/click interaction.

- Exposed `buildCamera`, `bookHitTargets`, `canvasWidth`, `canvasHeight` from `Scene.Room`
- Added `CanvasMouseMoved` and `CanvasClicked` Msg variants
- `Html.Events.on "mousemove"` / `"click"` with `offsetX`/`offsetY` decoders on canvas container
- `raycastAt` helper: builds camera + screen rect + hit targets → `Picking.pickBook`
- Hover updates `hoveredBookId` → triggers animation subscription → book pulls forward
- Click raycasts → navigates to BookDetail
- Pointer cursor when hovering a book

**Files**: `frontend/src/Page/Bookshelf.elm`, `frontend/src/Scene/Room.elm`, `frontend/src/Scene/Picking.elm`

---

## Phase 4: Atmospheric Compositing — COMPLETE

Layered cinematic overlays on top of the WebGL canvas.

- Vignette: `mix-blend-mode: multiply`, `opacity: 0.5` — darkens edges
- Light leak: `mix-blend-mode: screen`, `opacity: 0.25` — warm golden beam from upper right
- Dust motes: `mix-blend-mode: screen`, `opacity: 0.12`, `animation: dust-drift 8s ease-in-out infinite` — floating particles
- All overlays: `position: absolute`, `pointer-events: none`, `aria-hidden: true`
- `@keyframes dust-drift` added to `frontend/css/main.css`

**Files**: `frontend/src/Page/Bookshelf.elm`, `frontend/css/main.css`

---

## Verification Checklist

- [x] `elm make src/Main.elm` — compiles clean
- [x] `elm-test` — 258 tests passing (251 original + 7 BookMesh)
- [x] `elm-review` — 0 errors, 0 suppressions
- [x] CSP `img-src` includes `blob:`
- [x] Canvas mouse interaction wired (Phase 3.5)
- [x] Atmospheric overlays composited (Phase 4)
- [ ] Manual test in Brave with Shields up — WebGL renders (needs deploy)

---

## Future Phases (not this branch)

- **Phase 5**: Login dolly-shot in WebGL (full 3D corridor, doors, camera path)
- **Phase 6**: Room-to-room camera transitions (hoist scene state to Main.Model)
- **Phase 7**: PBR materials — upgrade to `Material.bumpyNonmetal` with generated normal maps, specular highlights
- **Phase 8**: Reading Pile 3D nook, Looking for a Home 3D pile
- **Phase 9**: CSS 3D removal and cleanup
