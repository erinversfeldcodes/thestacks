# Issue #072: Vision Service Extensions — /associate Endpoint and image_url Parameter

## Summary
The vision sidecar (`apps/vision/`) currently exposes `/classify` and `/extract`. The consolidated roadmap requires two additions: (1) a `/associate` endpoint that links a verified ISBN to a book record in the core DB via a callback, and (2) an `image_url` parameter on `/extract` so that remote image URLs (e.g., from Open Library cover CDN) can be processed without uploading a file. Without these, the enrichment pipeline (#057, #058) cannot coordinate with the vision service.

## User Stories
US-6.1.x (Vision-assisted book intake), US-6.2.x (Cover image processing)

## Goal
Extend the vision sidecar with `/associate` and the `image_url` parameter on `/extract`. The Elixir `Stacks.AI.Client` must be updated to call these new endpoints. The `endpoint_path/1` mapping in `Stacks.AI.Client` is the single translation point — Python paths must not change once documented.

## Technical Requirements

**`/associate` endpoint (Python FastAPI):**
- `POST /associate`
- Request body: `{ "isbn": "978-...", "book_id": "<uuid>", "edition_id": "<uuid>", "cover_image_url": "<url>" }`
- Behaviour:
  1. Validate ISBN format (reuse existing ISBN validation)
  2. Download cover image from `cover_image_url` (with 10s timeout; reject if >10 MB)
  3. Run classify pipeline on downloaded image to confirm it is a book cover
  4. If confirmed: POST callback to `CORE_API_URL/api/internal/vision/associate` with `{isbn, book_id, edition_id, status: "confirmed"}` + HMAC signature
  5. If not confirmed: POST callback with `{status: "rejected", reason: "not_a_book_cover"}`
- HMAC header: `X-Vision-Signature` — same secret as existing `VISION_HMAC_SECRET`
- Response: `{"job_id": "<uuid>"}` (async — callback delivers result)
- Idempotent: same `edition_id` processed twice returns same response without re-running

**`image_url` parameter on `/extract`:**
- Existing: `POST /extract` accepts multipart file upload
- New: also accept `{ "image_url": "<url>" }` JSON body (mutually exclusive with file upload)
- If `image_url` provided: download image (10s timeout, 10 MB limit), run extraction pipeline
- Error if both file and `image_url` provided
- Error if neither provided

**`apps/vision/app/config.py`:**
- Add `CORE_API_URL: str` — required env var; no default (must be set in production)
- Add `VISION_INTERNAL_TOKEN: str` — HMAC secret (already exists as `VISION_HMAC_SECRET` — alias or rename)

**`Stacks.AI.Client` updates (`apps/core/lib/stacks/ai/client.ex`):**
- Add `"associate"` → `/associate` mapping in `endpoint_path/1`
- Add `associate_isbn/4` function: `associate_isbn(isbn, book_id, edition_id, cover_url)` — POST to `/associate`, returns `{:ok, job_id}` or `{:error, reason}`
- Add `extract_from_url/1` function: `extract_from_url(image_url)` — POST to `/extract` with `image_url` JSON body
- Existing `classify/1` and `extract/1` (file-based) remain unchanged

**`StacksWeb.InternalController` (new or extend existing):**
- `POST /api/internal/vision/associate` — receives callback from vision sidecar
- Validates HMAC signature on `X-Vision-Signature` header
- On `status: "confirmed"`: calls `Stacks.Books.confirm_cover_association/2`
- On `status: "rejected"`: logs warning, no state change
- Returns 200 regardless (vision sidecar must not retry on app errors)
- Route must be excluded from public-facing rate limiting (internal only)

**Tests:**
- Python: mock `httpx.AsyncClient` for cover download; test both confirmed and rejected paths
- Elixir: mock HTTP client (Bypass or Req.Test); test `associate_isbn/4` and `extract_from_url/1`; test InternalController HMAC validation (valid + tampered)

## Definition of Done
- [ ] `POST /associate` endpoint implemented with async callback pattern
- [ ] `/extract` accepts `image_url` parameter as alternative to file upload
- [ ] `Stacks.AI.Client` has `associate_isbn/4` and `extract_from_url/1`
- [ ] `endpoint_path/1` mapping updated
- [ ] `StacksWeb.InternalController` validates HMAC and dispatches to `Books.confirm_cover_association/2`
- [ ] Python tests pass (mocked HTTP)
- [ ] Elixir tests pass (mocked HTTP, HMAC validation)
- [ ] `ruff check` passes
- [ ] `mix credo --strict` passes

## Dependencies
Issue #043 (book_editions table for `edition_id` FK), Issue #003 (vision sidecar base must exist)

## Agent Assignment
python-agent (FastAPI endpoints) + elixir-agent (Client + InternalController)

## Progress Notes

Created 2026-03-19 as GAP-06 from roadmap gap analysis. Vision `/associate` coordination risk was flagged during enrichment pipeline analysis (#057 assumed this endpoint existed).

2026-03-19 — Wave A (Python) orchestrator review complete. Regression gate: 49 passed in 0.13s.
Reviewer verdict: NEEDS_REVISION — BLOCKER: zero tests for `/associate` and `image_url`. All 49 tests are pre-existing; the new features are entirely untested. Additional required revisions: (1) bare `assert` at main.py:170 (stripped by Python -O flag), (2) inline `import json` inside function body at main.py:119, (3) `core_api_url` empty-string default not enforced in production. These revisions remain open and must be addressed when this issue is revisited.

2026-03-19 — Elixir scope (`associate_isbn/4`, `extract_from_url/1`, `StacksWeb.InternalController`, `Books.confirm_cover_association/2`) moved to Issue #046. Rationale: the InternalController calls `confirm_cover_association/2` which is being built in #046 anyway; co-locating them in one issue avoids a half-implemented callback chain. Issue #072 is considered CLOSED on the Python side pending the three required revisions above, which are to be addressed at the start of #046 execution before the Elixir layer is built on top of them.
