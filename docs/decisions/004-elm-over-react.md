# ADR 004: Elm for the Frontend Instead of React or Vue

**Status:** Accepted
**Date:** 2026-03-05
**Deciders:** Platform owner
**Technical area:** Frontend architecture

---

## Context

The Stacks frontend is a single-page application that manages complex, interconnected UI state:

- Five named bookshelves, each with themed visual rendering
- Book detail overlay (opens over any page, dismissable)
- Multi-step upload flow with verification, duplicate detection, and multi-format merge
- Visibility/privacy controls with ceiling rules
- Real-time enrichment status (prices, reviews, author info loading asynchronously)
- Marketplace listing creation and checkout

This state machine demands robust UI state management. The primary risk in the frontend is runtime exceptions from unexpected state — a null reference, an unhandled union variant, a JSON decode error — crashing the interface mid-session.

**Candidates evaluated:**

| Framework | Runtime exceptions | Type safety | Learning curve | Bundle size | Notes |
|-----------|-------------------|-----------|--------------------|------------|-------|
| **React + TypeScript** | Possible (null refs, unhandled promises) | Good (but optional, escape hatches) | Low | ~40KB gzipped | Ubiquitous, large ecosystem |
| **Vue + TypeScript** | Possible | Good | Low-medium | ~30KB gzipped | Simpler state than React |
| **Elm** | Zero (compiler-enforced) | Total (no escape hatches) | Medium-high | ~30KB gzipped | Pure functional, TEA architecture |
| **SvelteKit** | Possible | Good (with TypeScript) | Medium | ~10KB gzipped | Compiled, newer |

**Project goals:**
- Zero runtime crashes in production — the user's reading life should not be interrupted by JavaScript errors.
- The bookshelf state machine (5 shelves, overlay, loading states, search, visibility levels) benefits from exhaustive pattern matching at compile time.
- Elm's `RemoteData` pattern (`NotAsked | Loading | Success a | Failure e`) models async API calls without null-check errors.
- The compiler-as-tests property: Elm's compiler enforces that every union variant is handled, every Maybe is unwrapped, every JSON decoder is correct.

**Security note:** Elm does not require `'unsafe-eval'` in the Content Security Policy — it compiles to safe JavaScript with no `eval()` calls. This is a meaningful security advantage over frameworks that use template compilation or runtime codegen.

---

## Decision

**Use Elm for the frontend SPA.**

**Architecture:** The Elm Architecture (TEA) — Model, Update, View. The model is the single source of truth for all UI state. Updates are pure functions. Side effects are explicit commands and subscriptions.

**Key patterns:**
- `RemoteData` for all API calls — `NotAsked | Loading | Success a | Failure e`. No manual loading-state booleans.
- `Maybe` for optional values — no null references.
- Union types for UI state machines (e.g., `UploadStep`, `SearchScope`, `Visibility`).
- No ports unless absolutely necessary (file input interop, swipe gesture detection on mobile).

**Module structure** (`frontend/src/`):
- `Page/` — page-level modules (Upload, Bookshelf, Search, Settings, etc.)
- `Components/` — reusable components (Spine, ISBNInput, FilterPanel, etc.)
- `Types/` — shared types (Book, Placement, User, RemoteData)
- `Navigation/` — routing (ShelfRouter)
- `Animation/` — transitions (SlideTransition, RoomTransition)
- `Api.elm` — HTTP client module

**Decoders:** Elm JSON decoders are checked in (`proto/gen/elm/`). No runtime codegen. Generated from Protobuf schemas via `buf generate`.

**Build pipeline:** `elm make src/Main.elm --optimize` → esbuild bundles → `app.js`. The browser loads `app.js`, not a standalone `elm.js`. esbuild applies dead-code elimination on the compiled output.

**Tooling:**
- `elm-format` — enforced in CI
- `elm-test` — unit and integration tests
- `elm-review` — code quality analysis
- `elm make --optimize` — zero-warning build in CI

---

## Consequences

**Positive:**
- Zero runtime exceptions in production — the Elm compiler is the enforcement mechanism. The "Elm guarantee" is not aspirational; it is structural.
- Exhaustive pattern matching — adding a new union variant forces every case expression to be updated at compile time.
- `RemoteData` eliminates entire categories of bugs: loading-but-no-data, success-but-null, error-but-displayed-as-success.
- CSP-compatible: no `unsafe-eval` needed.
- Elm's package ecosystem is small and auditable — no dependency CVE scanner needed (the dependency graph is tiny and human-reviewable).
- Elm's time-travelling debugger (`elm-debug-transform`) makes production bug reproduction straightforward.

**Negative:**
- Smaller community and ecosystem than React/Vue — fewer pre-built components, less Stack Overflow coverage.
- Learning curve for contributors unfamiliar with functional programming or Elm specifically.
- Interop with JavaScript libraries requires ports or web components — more boilerplate than React's `npm install anything`.
- Elm's HTTP library does not support streaming responses — not a constraint for current features, but worth noting for future real-time capabilities.
- Generated Protobuf decoders for Elm are checked in and must be kept in sync with `.proto` file changes (no runtime codegen). This is enforced by `buf lint` and `buf breaking` in CI.

**Migration path:**
- If Elm becomes a blocker (e.g., a required UI library has no Elm binding), individual sections can be migrated to Web Components or a separate React micro-frontend served at a distinct route. The Elm app would remain for the core shelving experience. This is a last resort — the architecture deliberately minimises JavaScript interop.
