# Retrospective: Local OCR Pre-pass for ISBN Extraction
**Issue**: #007
**Date**: 2026-03-14
**Phases completed**: 1
**Agents involved**: python-agent

---

## What Worked Well

- **Single-phase plan was correct**: The work was tightly coupled (config, function, endpoint, tests) and didn't benefit from parallelisation. No wasted orchestration overhead.
- **Test-first protocol produced clean implementation**: 8 unit tests + 3 integration tests were written before any production code. The implementation passed all tests on first run with no test modifications needed.
- **E2E test validated the full pipeline**: The barcode pre-pass E2E test (11.5s) confirmed the entire flow works end-to-end — Playwright → Phoenix → Oban → vision service (barcode decoded, VLM skipped) → Open Library → book rendered in Elm. Server logs confirmed `candidate 1 has direct ISBN 9780156001311`.
- **Worktree isolation worked**: The python-agent implemented in an isolated worktree, and changes were cleanly copied to the feature branch without conflicts.

---

## What Caused Friction

- **Auth rate limit blocked E2E tests (3 deploy attempts)**: The auth rate limit (5/min per IP) was too tight for a test suite that logs in 10+ times. This wasn't caught until the deployed E2E run. Root cause: the rate limit was designed for production users, not automated test suites hitting the same endpoint repeatedly. The fix (configurable via `RATE_LIMIT_AUTH` env var) was straightforward but cost 3 deploy cycles (~10 min each) to diagnose and verify.
- **Local inference tangent (abandoned)**: Significant time was spent attempting to add a `LocalVisionModel` for running Qwen2.5-VL locally to support local E2E tests. This failed due to: (1) transformers 5.x incompatibility with model weights, (2) accelerate offloading crashes on macOS with insufficient RAM. The entire approach was scrapped in favour of running E2E tests against a deployed stack. Root cause: the plan didn't account for hardware constraints of local inference.
- **Modal cleanup command wrong**: `modal app delete` doesn't exist in current Modal CLI — the correct command is `modal app stop`. This was silently swallowed by `2>/dev/null`, making it appear to work while leaving Modal apps running. Pre-existing bug, not introduced by this issue.
- **Docker layer caching masked config changes**: The rate limit fix was committed and pushed, but the Fly deploy reused cached Docker layers that didn't include the updated `runtime.exs`. Root cause: Depot's build cache keyed on layer content hashes that matched a previous build.
- **Security scanning tools not installed**: `trufflehog`, `syft`, `grype`, `dockle`, and `dbt-checkpoint` were referenced by `scripts/security.sh` but not listed in the Brewfile or setup.sh. Pre-existing gap.

---

## What Should Change in the Agent System

| File | Change | Addresses friction point |
|------|--------|--------------------------|
| `docs/agents/orchestrator-agent.md` | Add guidance: "For E2E tests against deployed stacks, verify that rate limits accommodate the test suite's login frequency before the first deploy" | Auth rate limit blocking E2E tests |
| `docs/agents/python-agent.md` | Add to Key Patterns: "Local GPU inference (torch + transformers) is not viable on dev machines for 7B+ parameter models. Always target deployed Modal infrastructure for inference testing." | Local inference tangent |
| `scripts/cleanup-preview.sh` | Already fixed: `modal app delete` → `modal app stop` | Modal cleanup silently failing |
| `Brewfile` + `setup.sh` | Already fixed: added missing security tools | Security scanning tools not installed |

---

## Suggested Issues

- [ ] Share auth state across E2E upload tests — sign in once per `test.describe` block using Playwright's `storageState`, eliminating repeated `signIn()` calls and rate limit pressure
- [ ] Audit Modal app lifecycle — verify all preview Modal apps are being cleaned up; check for orphaned apps from previous failed runs
- [ ] Add `--no-cache` flag to preview deploys — or add a cache-busting build arg to prevent stale Docker layers from masking config changes
