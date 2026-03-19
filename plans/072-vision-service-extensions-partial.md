# Plan: Vision Service Extensions — /associate Endpoint and image_url Parameter
**Issue**: #072
**Created**: 2026-03-19
**Status**: Python Complete — Elixir Deferred to Wave B

---

## Context

The vision sidecar (`apps/vision/`) required two additions: (1) a `/associate` endpoint that
classifies a cover image and POSTs a callback to the core API with the result, and (2) an
`image_url` parameter on `/extract` so remote image URLs can be processed without a file upload.
The Python FastAPI side has been implemented. The Elixir side (`Stacks.AI.Client` and
`StacksWeb.InternalController`) is deferred to Wave B.

---

## Wave A: Python FastAPI (Complete — Pending Blocker Resolution)

### What Was Implemented

**Files created/modified:**
- `apps/vision/app/models/association.py` — `AssociateRequest`, `AssociateResponse` Pydantic models
- `apps/vision/app/models/extraction.py` — `ExtractionRequest` extended with `image_url` field and
  `@model_validator` enforcing mutual exclusivity with `images`
- `apps/vision/app/main.py` — `/associate` endpoint (async, idempotent per `edition_id`, HMAC
  callback); `/extract` extended with `image_url` path; `_download_image` helper;
  `_sign_callback` helper

### Regression Gate Result (2026-03-19)

```
49 passed in 0.13s
```

All 49 tests pass. `ruff check` clean and `ruff format --check` clean per python-agent report.

### Review Verdict: NEEDS_REVISION

**Blocker:** The 49 tests are entirely pre-existing. There are **zero tests** for the two new
features: `/associate` endpoint and `image_url` path on `/extract`. The issue DoD explicitly
requires Python tests covering both confirmed and rejected paths, mocked HTTP. This is a test
completeness failure (Reviewer Axis 0 — Test-First Compliance), which is a mandatory blocker.

**Additional required revisions (non-blocking individually, but required before merge):**

1. `apps/vision/app/main.py:170` — bare `assert body.images is not None` in production code path.
   Python's `-O` flag silently removes `assert` statements; this should be an explicit `if`
   guard with an appropriate `HTTPException` or `raise AssertionError`.
2. `apps/vision/app/main.py:119` — `import json` inside the `_run_associate` function body.
   Move to module-level imports at the top of `main.py`.
3. `apps/vision/app/main.py:55` and `main.py:126` — `httpx.AsyncClient` is instantiated
   per-call in `_download_image` (and per background-task invocation of `_run_associate`).
   No connection reuse or pool sizing. Advisory — acceptable for low-volume internal use, but
   should be noted for forward compatibility with enrichment pipeline throughput.
4. `apps/vision/app/config.py:26` — `core_api_url` has an empty string default (`""`).
   The issue requires no default in production. The validator does not enforce this for
   non-test environments. Should raise `ValueError` when `core_api_url == ""` and
   `environment != "test"`.

### Spec Coverage Audit (Python Side)

| Required Item | Implemented | Tested |
|---|---|---|
| `POST /associate` endpoint | Yes (`main.py:228`) | NO — blocker |
| `/associate` idempotency per `edition_id` | Yes (`main.py:244`) | NO |
| HMAC callback (`X-Vision-Signature`) | Yes (`main.py:76`, `122`) | NO |
| `image_url` on `/extract` (mutually exclusive) | Yes (`extraction.py:20`) | NO |
| `_download_image` size + timeout limits | Yes (`main.py:52`) | NO |
| `AssociateRequest` / `AssociateResponse` models | Yes (`models/association.py`) | NO |
| `config.py` `CORE_API_URL` / `core_api_url` | Partial (empty string default, no prod enforcement) | NO |

---

## Wave B: Elixir (Deferred)

The following DoD items are NOT implemented and are deferred to Wave B:

- `Stacks.AI.Client`: `associate_isbn/4` function
- `Stacks.AI.Client`: `extract_from_url/1` function
- `Stacks.AI.Client`: `endpoint_path/1` mapping updated with `"associate"` → `/associate`
- `StacksWeb.InternalController`: `POST /api/internal/vision/associate` callback handler
- HMAC validation in `InternalController` (valid + tampered token)
- `Stacks.Books.confirm_cover_association/2` (called from InternalController on `"confirmed"`)
- Elixir tests: mocked HTTP, HMAC validation
- `mix credo --strict` passes

**Wave B should be picked up as a continuation of Issue #072 once Wave A blockers are resolved.**

---

## DoD Verification

| DoD Item | Status |
|---|---|
| `POST /associate` endpoint implemented with async callback pattern | Python: Implemented, not tested (BLOCKER) |
| `/extract` accepts `image_url` parameter as alternative to file upload | Python: Implemented, not tested (BLOCKER) |
| `Stacks.AI.Client` has `associate_isbn/4` and `extract_from_url/1` | Deferred (Wave B) |
| `endpoint_path/1` mapping updated | Deferred (Wave B) |
| `StacksWeb.InternalController` validates HMAC and dispatches | Deferred (Wave B) |
| Python tests pass (mocked HTTP) | FAILED — no tests for new features |
| Elixir tests pass (mocked HTTP, HMAC validation) | Deferred (Wave B) |
| `ruff check` passes | PASS |
| `mix credo --strict` passes | Deferred (Wave B) |

---

## Next Steps

1. **Resolve blocker**: python-agent to write tests for `/associate` (confirmed + rejected paths,
   idempotency, HMAC callback signing, download errors) and `image_url` on `/extract` (happy path,
   size limit, timeout, mutual exclusivity). Tests must use mocked `httpx.AsyncClient`.
2. **Fix non-blocking issues**: bare `assert`, inline `import json`, `core_api_url` production enforcement.
3. Re-run regression gate and reviewer.
4. On Wave A approval: commence Wave B (Elixir) as a follow-on phase of Issue #072.
