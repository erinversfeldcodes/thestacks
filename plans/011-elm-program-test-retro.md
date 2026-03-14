# Retrospective: elm-program-test User Journey Coverage
**Issue**: #011
**Date**: 2026-03-14
**Phases completed**: 4
**Agents involved**: elm-agent

---

## What Worked Well

- **Parallel phase execution**: Phases 2, 3, 4 were independent and could run in parallel (though in practice they ran sequentially due to shared worktree). Each phase was self-contained with clear scope.
- **TestHelpers.elm as shared infrastructure**: Creating harnesses + HTTP simulators in Phase 1 made Phases 2-4 straightforward — agents could focus on test logic rather than plumbing.
- **elm-review auto-fix**: The 6 NoUnused findings were caught by CI and auto-fixed with `elm-review --fix-all` in seconds.
- **Test count scaling**: 22 tests added, total suite still runs in ~200ms. elm-program-test's virtual DOM approach delivers on the "millisecond execution" promise.
- **Agent self-correction**: The Upload program tests had 2 failures mid-implementation (decoder mismatch in TestHelpers.elm). The agent diagnosed and fixed them within the same session without orchestrator intervention.

---

## What Caused Friction

- **Queued prompts not picked up**: Phases 3 and 4 were queued to the same agent via `resume`, but the agent completed Phase 2 and exited without processing the queued prompts. Required re-launching the agent twice. Root cause: Agent tool `resume` with queued prompts is unreliable — completed agents don't process queued messages.
- **elm-format not on PATH**: All three hook scripts (pre-commit, post-tool, stop) hardcoded `elm-format` as a bare command, but it's only installed in `frontend/node_modules/.bin/`. This blocked commits and triggered false hook failures. Root cause: hooks were written assuming global tool installation.
- **Recurring lost fixes across branches**: The `modal app stop` fix, `shell=True` fix, and `type: ignore[import-untyped]` fix were all applied in earlier sessions but lost when branches changed. Root cause: fixes were applied to working tree state that was never committed, or committed on a different branch.
- **Docker cache preventing config deployment**: The `RATE_LIMIT_AUTH=60` runtime.exs change was committed and pushed, but Fly's Depot builder reused cached Docker layers that didn't include it. Three deploys failed before adding `--no-cache`. Root cause: `fly deploy` uses content-hash-based layer caching; config-only changes in intermediate layers don't always bust the cache.
- **E2E login rate limiting (persistent)**: Despite the `RATE_LIMIT_AUTH` config and `--no-cache` fixes, the 429 on test 9 persisted across 4+ deploy attempts. Fixed pragmatically with retry logic in `signIn()`. Root cause: multiple compounding issues (Docker cache, two Fly machines with independent ETS tables, config not propagating).

---

## What Should Change in the Agent System

| File | Change | Addresses friction point |
|------|--------|--------------------------|
| `docs/agents/orchestrator-agent.md` | Add guidance: "Do not queue multiple prompts to a single agent via `resume`. Launch separate agents for each independent phase." | Queued prompts not picked up |
| `.claude/hooks/post-tool-lint.sh`, `scripts/hooks/pre-commit`, `scripts/hooks/lib/pre-stop-lint.sh` | Already fixed: resolve `elm-format` from `frontend/node_modules/.bin/` before falling back to PATH | elm-format not on PATH |
| `scripts/deploy-preview.sh` | Already fixed: `--no-cache` on `fly deploy` for preview builds | Docker cache preventing config deployment |
| `docs/agents/orchestrator-agent.md` | Add to Phase 2E: "After human confirms commit, verify the fix is committed before proceeding. Do not apply fixes to working tree without committing — they will be lost on branch switches." | Recurring lost fixes |

---

## Suggested Issues

- [ ] Share Playwright auth state across upload tests — sign in once per `test.describe` using `test.beforeAll` + cookie/token injection, eliminating repeated `signIn()` calls
- [ ] Audit all hook scripts for tool resolution — ensure every tool reference (elm-format, elm-review, elm-test, cargo, mix) uses the local/project-specific binary first, falling back to PATH
- [ ] Add `--no-cache` flag as configurable option in deploy-preview.sh — default to `--no-cache` for preview deploys but allow opt-in caching for speed when debugging
