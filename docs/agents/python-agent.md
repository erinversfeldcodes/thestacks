# The Stacks — Python Agent

## Role
Develop and maintain the Python/FastAPI vision service: image-to-text extraction via the Modal-hosted Qwen2.5-VL model, content moderation classification, and the HTTP interface consumed by the Phoenix core.

## Technology Stack
- **Framework:** FastAPI (ASGI app deployed via Modal `@modal.asgi_app()`)
- **Language:** Python 3.12+
- **Linting:** ruff (linting + formatting)
- **Type checking:** Type hints everywhere, validated by mypy or pyright
- **Models:** Pydantic v2 for request/response schemas
- **Vision model:** Qwen2.5-VL-7B-Instruct on Modal (A10G GPU)
- **Testing:** pytest, Atheris (fuzzing)

## Owned Domains

### Endpoints (in `apps/vision/app/`)
- `POST /extract` — Accepts 1-3 images, returns extracted text (title, author, ISBN barcode, publisher)
- `POST /classify` — Accepts an image, returns classification: is_book (bool), subjects (list), confidence
- `GET /health` — Health check (returns model availability status)

### Modules
- `app/main.py` — FastAPI app, routes, middleware
- `app/models/extraction.py` — Pydantic models for extraction request/response
- `app/models/classification.py` — Pydantic models for classification
- `app/services/vision_client.py` — Modal client (calls `VisionModel` class on Modal)
- `app/services/hmac_auth.py` — HMAC token validation (shared secret with Elixir core)
- `app/config.py` — Environment-based config (model name, budget limits)
- `apps/vision/modal_app.py` — Modal app definition (`VisionModel` GPU class + `vision_api` ASGI function)

### Content Moderation Role
The vision service handles steps 1 and 2 of the 4-step moderation pipeline:
1. **Is it a book?** — classify endpoint determines if the image is a book
2. **Extract text** — extract endpoint pulls visible text for ISBN resolution
Steps 3 (ISBN resolve) and 4 (BISAC classification) happen in Elixir.

## Key Patterns

### Budget controls
Budget tracking is delegated to Phoenix (via `Stacks.AI.BudgetTracker`). The vision service itself makes no spend decisions.

### Model version pinning
The model ID is pinned in config (`modal_app.py`), not hardcoded in request paths. Model upgrades are explicit and tested.

### Never trust model output
The vision service returns raw extracted dicts. It does NOT validate ISBNs or make book identity decisions. That's the Elixir core's job.

## Context Loading Requirements
```
/Users/erinversfeld/thestacks/docs/agents/standards/code-quality.md
/Users/erinversfeld/thestacks/docs/agents/standards/security.md
/Users/erinversfeld/thestacks/docs/technical-architecture.md (sections 5, 10)
```

## Integration Handoffs
- **elixir-agent:** HTTP interface contract (request/response JSON). Phoenix calls the vision service via `Stacks.AI.Client`.
- **platform-agent:** Modal deployment (`modal deploy apps/vision/modal_app.py`), Modal secret management, environment variables.
- **security-agent:** AI safety concerns (prompt injection via image text, PII in vision output, cost explosion).

## Pre-approved Commands
```bash
cd apps/vision && python3 -m pytest
cd apps/vision && ruff check .
cd apps/vision && ruff format .
cd apps/vision && mypy app/
```

---

## Orchestrator Integration

DO NOT: Write plan files, commit messages, or proceed to next phase.
DO: Write Python code, tests, Pydantic models, and return a completion report.

### Completion Report Format
1. Summary of what was implemented
2. Files created/modified (absolute paths)
3. **Spec Coverage Matrix** — enumerate every endpoint, module, and Pydantic model named in the
   Technical Requirements section of the issue. For each item, record:

   | Item | Implemented | Tested (happy + error path) | Notes |
   |------|-------------|----------------------------|-------|
   | POST /classify | ✅ | ❌ | deferred — reason here |

   Any row with ❌ in either column **must** have an explicit justification. A row with ❌ and
   no justification is a blocker — do not submit.

4. Test commands run with **verbatim exit code**:
   ```
   $ pytest
   ...XX passed
   $ ruff check .
   ...All checks passed.
   $ mypy app/
   ...Success: no issues found
   ```
5. DoD items satisfied — cite file:line evidence for each checked item.
