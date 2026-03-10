# Issue #003: Implement Python FastAPI vision sidecar

## Summary
Build the FastAPI vision sidecar with `/extract`, `/classify`, and `/health` endpoints, HMAC auth, Pydantic models, and a Together AI / Replicate HTTP client. This service is called by Phoenix to identify books from uploaded images. This is Phase 1D of the consolidated roadmap.

## User Stories
- US-1.1.1 — Photo upload triggers book identification pipeline
- US-1.1.2 — ISBN Hard Gate (sidecar returns extraction; Phoenix validates)
- US-1.1.3 — Non-Book Rejection (`not_book` classification)

## Goal
A production-ready FastAPI service with three endpoints, full HMAC request authentication, Pydantic-validated I/O, and a pinned model client. Phoenix calls this service; the sidecar never trusts its own model output — it returns raw extractions and lets Phoenix validate against Open Library / Google Books.

## Technical Requirements

See roadmap: `plans/consolidated-roadmap.md` § Phase 1D.

**Endpoints:**

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/extract` | Image → extracted text (title, author, potential ISBNs) |
| `POST` | `/classify` | Image → `{classification: "book" \| "not_book" \| "ambiguous", confidence: float}` |
| `GET`  | `/health` | Health check → 200 |

**Files:**
- `apps/vision/app/main.py` — FastAPI app, route registration, lifespan
- `apps/vision/app/models/extraction.py` — Pydantic request/response models for `/extract`
- `apps/vision/app/models/classification.py` — Pydantic models for `/classify`
- `apps/vision/app/services/vision_client.py` — Together AI / Replicate HTTP client (model pinned to `Qwen/Qwen2.5-VL-7B-Instruct`)
- `apps/vision/app/services/hmac_auth.py` — HMAC token validation; rejects unsigned requests with 401
- `apps/vision/app/config.py` — model version, budget defaults, env var loading
- `apps/vision/tests/` — pytest test files (happy path + auth rejection + bad input)
- `apps/vision/requirements.txt` — pinned deps
- `apps/vision/Dockerfile` — Python 3.12 slim, multi-stage

**Constraints:**
- Never trust model output — return raw extractions only; validation is Phoenix's responsibility
- Model version pinned in `config.py` — no floating `latest`
- Budget tracking delegated entirely to Phoenix — sidecar makes calls, Phoenix decides whether to allow them
- HMAC auth (`X-Internal-Token` header) on all non-health endpoints — no unauthenticated access
- `ruff check` and `ruff format --check` must pass
- Type hints on all functions

## Definition of Done
- [ ] `/extract` returns structured JSON: `{title, author, potential_isbns: []}`
- [ ] `/classify` returns `{classification: "book" | "not_book" | "ambiguous", confidence: float}`
- [ ] `/health` returns 200
- [ ] HMAC auth rejects unsigned requests with 401
- [ ] All request/response types have Pydantic model validation
- [ ] `ruff check` passes
- [ ] `ruff format --check` passes
- [ ] Type hints on all functions
- [ ] `python -m pytest` passes

## Dependencies
- Repository scaffolding complete ✅ (`apps/vision/` skeleton exists)

## Architecture Decision: Endpoint Naming

The Phoenix `AI.Client` calls `call_vision/2` with semantic names (`"is_book"`, `"extract_isbn"`) and currently constructs URLs by appending the name directly to the base URL. The Python sidecar defines REST resource paths (`/extract`, `/classify`).

**Decision: keep the Python paths as specified. Fix the mapping in Elixir.**

The Python paths (`/extract`, `/classify`) are idiomatic REST — they name the resource/operation from an HTTP perspective. Renaming them to verb phrases like `/is_book` or `/extract_isbn` would be non-idiomatic FastAPI.

The Elixir fix is a small private mapping function in `Stacks.AI.Client`:

```elixir
defp endpoint_path("is_book"), do: "classify"
defp endpoint_path("extract_isbn"), do: "extract"
defp endpoint_path(other), do: other
```

This is idiomatic Elixir pattern matching. The domain layer continues to use intent-describing names; the HTTP path is an implementation detail of the client.

**The python-agent must not change endpoint paths to match Elixir naming.** The Elixir mapping fix is tracked as pre-work in Issue #001.

## Agent Assignment
- **python-agent** (`docs/agents/python-agent.md`)
- **Reviewer**: python-reviewer (`docs/agents/reviewers/python-reviewer.md`)
- **Model**: Sonnet 4.6

## Progress Notes
<!-- Updated by agents during execution -->
