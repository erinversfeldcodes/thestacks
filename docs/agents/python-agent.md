# The Stacks — Python Agent

## Role
Develop and maintain the Python/FastAPI vision sidecar: image-to-text extraction via hosted open-source vision models, content moderation classification, and the HTTP interface consumed by the Phoenix core.

## Technology Stack
- **Framework:** FastAPI
- **Language:** Python 3.12+
- **Linting:** ruff (linting + formatting)
- **Type checking:** Type hints everywhere, validated by mypy or pyright
- **Models:** Pydantic v2 for request/response schemas
- **Vision model providers:** Together AI, Replicate (hosted open-source: Qwen2.5-VL, Llama 4 Scout, PaliGemma 2)
- **Testing:** pytest, Atheris (fuzzing)

## Owned Domains

### Endpoints (in `apps/vision/app/`)
- `POST /extract` — Accepts 1-3 images, returns extracted text (title, author, ISBN barcode, publisher)
- `POST /classify` — Accepts an image, returns classification: is_book (bool), subjects (list), confidence
- `GET /health` — Health check (returns model availability status)

### Modules
- `app/main.py` — FastAPI app, routes, middleware
- `app/models/extract.py` — Pydantic models for extraction request/response
- `app/models/classify.py` — Pydantic models for classification
- `app/providers/together.py` — Together AI client
- `app/providers/replicate.py` — Replicate client
- `app/providers/base.py` — Provider interface (swap models via config)
- `app/config.py` — Environment-based config (model name, provider, budget limits)

### Content Moderation Role
The vision sidecar handles steps 1 and 2 of the 4-step moderation pipeline:
1. **Is it a book?** — classify endpoint determines if the image is a book
2. **Extract text** — extract endpoint pulls visible text for ISBN resolution
Steps 3 (ISBN resolve) and 4 (BISAC classification) happen in Elixir.

## Key Patterns

### Budget controls
The sidecar tracks per-day and per-month spend. If budget is exceeded, it returns a 429 with a clear message. The Phoenix core handles graceful degradation.

### Model version pinning
The model ID is pinned in config, not hardcoded. Model upgrades are explicit and tested.

### Never trust model output
The sidecar returns raw extracted text. It does NOT validate ISBNs or make book identity decisions. That's the Elixir core's job.

## Context Loading Requirements
```
/Users/erinversfeld/thestacks/docs/agents/standards/code-quality.md
/Users/erinversfeld/thestacks/docs/agents/standards/security.md
/Users/erinversfeld/thestacks/docs/technical-architecture.md (sections 5, 10)
```

## Integration Handoffs
- **elixir-agent:** HTTP interface contract (request/response JSON). Phoenix calls the sidecar via HTTPoison/Req.
- **platform-agent:** Dockerfile, Fly Machine config, environment variables for API keys and budget limits.
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
3. Test commands run and results
4. DoD items satisfied for this phase
