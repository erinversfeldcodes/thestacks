# Wave A Completion Plan

**Date:** 2026-03-19
**Status:** In Progress

---

## Steps

### 1. Issue #072 Regression Gate

Run `pytest` in `apps/vision/` to verify all tests pass. Tests for `/associate` and `image_url` already exist in `test_association.py` and `test_extraction.py`. Non-blocking reviewer fixes have already been applied. Re-submit to python-reviewer for an APPROVED verdict before proceeding.

```
cd apps/vision && pytest
```

### 2. elm-format proto/gen/elm

Run `elm-format` on the two hand-rewritten Elm files that were checked in as source but are outside the `frontend/src/` path that `lint-elm.sh` validates:

- `proto/gen/elm/Stacks/Common/V1/Location.elm`
- `proto/gen/elm/Stacks/Internal/V1/EventBus.elm`

```
elm-format proto/gen/elm/Stacks/Common/V1/Location.elm
elm-format proto/gen/elm/Stacks/Internal/V1/EventBus.elm
```

### 3. Full CI Gate

Run the complete CI suite against the composed `feat/wave_a` branch. This is the first time the full suite runs against all Wave A changes together:

```
scripts/ci.sh
```

All groups must pass: elixir, elm, rust, python, proto, security, dbt, squawk, licenses.

### 4. Deploy and E2E

Deploy the preview stack and run the Playwright E2E suite:

```
scripts/deploy-stack.sh --branch feat/wave_a
```

Then run the full Playwright suite. Target: all tests pass. The previous run was 109/111; selector fixes have since been applied so all 111 should now pass.

### 5. Principal Engineer Review

Engage the `principle-engineer` agent for a holistic assessment of all Wave A changes across every stack:

- Event Bus (Protobuf-backed)
- Protobuf schema additions and generated artifacts
- Rust scraper changes
- SearXNG integration
- Vision service extensions (Issues #072)
- Tooling and infrastructure changes

The agent should review for architectural consistency, cross-stack contract integrity, security posture, and readiness to merge to `main`.

### 6. User Story Progression Evaluation

For each Wave A issue — **045, 049, 062, 070, 071, 072** — look up the user story it claims to support in `docs/user-stories.md` and assess:

- Whether the completed work meaningfully moves the platform toward that story.
- What additional in-scope work would further progress the story.
- Whether any gaps should be captured as new issues before closing Wave A.

Document findings inline or as a separate assessment note.

### 7. Cleanup

Tear down preview resources once E2E and reviews are complete:

```
scripts/cleanup-preview.sh --branch feat/wave_a
```

### 8. Retros

Write retrospective files for each Wave A issue following the structure and style of `plans/005-neon-preview-branch-data-isolation-retro.md`:

- `plans/045-*-retro.md`
- `plans/049-*-retro.md`
- `plans/062-*-retro.md`
- `plans/070-*-retro.md`
- `plans/071-*-retro.md`

Each retro should cover: what was built, what went well, what was painful, and any lessons that should inform Wave B planning or standing conventions.
