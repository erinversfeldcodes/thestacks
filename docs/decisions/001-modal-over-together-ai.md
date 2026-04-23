# ADR 001: Modal for Vision Inference, Together AI for Summarisation

**Status:** Accepted — partially superseded by [ADR 015](015-vision-service-architecture.md)
**Date:** 2026-03-17
**Deciders:** Platform owner
**Technical area:** AI infrastructure, external services

> **Update (2026-04-23):** the core decision in this ADR — Modal for
> vision, Together AI for summarisation — is unchanged. However the
> vision service's GPU class, model variant, engine version, and
> quantization strategy have evolved since this document was written.
> For the current state of the vision service (H100 instead of A10G,
> AWQ-quantized weights, vLLM v1, single `/analyze` endpoint, and the
> reasons for each change) see [ADR 015](015-vision-service-architecture.md).
> Treat the "Vision model selected" and GPU references in this ADR as
> historical context, not current configuration.

---

## Context

The Stacks requires two distinct AI capabilities:

1. **Vision inference** — classifying book photos and extracting ISBNs/titles from images (interactive, user-facing, latency-sensitive). Runs on every photo upload.
2. **Review summarisation** — condensing scraped reviews into short summaries (background job, no latency expectation). Runs asynchronously after enrichment.

Both capabilities require GPU inference. The question was whether to use a single provider for both, and if not, which provider for each.

**Candidates evaluated:**

| Provider | Cold start | Cost model | Notes |
|----------|-----------|-----------|-------|
| Modal | 15–30s (cached containers) | Per-second GPU time | Containers cached between invocations on the same machine |
| Together AI | 2–3 min (raw GPU allocation) | Per token | No container caching — each cold start allocates a new GPU |
| Replicate | 30–120s (varies by model) | Per-second | Caching varies by popularity of model |
| Managed APIs (Claude, GPT-4V) | ~0ms | Per token | No self-hosted model option |

**Key constraint:** The project goal explicitly includes demonstrating self-hosted model deployment. Managed vision APIs (Claude, GPT-4V) were ruled out for this reason — the platform owner wanted control over the inference environment and visibility into what happens to user-uploaded book photos.

**Vision model selected:** `Qwen/Qwen2.5-VL-7B-Instruct` on an NVIDIA A10G GPU via Modal.

**Summarisation model selected:** `meta-llama/Llama-4-Scout-17B-16E-Instruct` via Together AI.

---

## Decision

**Use Modal for vision inference and Together AI for review summarisation.**

The split is driven by latency requirements:

- **Vision (Modal):** The upload flow is interactive — the user is waiting for "We think this is…" feedback. A 2–3 minute cold start (Together AI without container caching) is unacceptable for this interaction. Modal's container caching keeps cold starts in the 15–30 second range, which is acceptable for bursty upload batches (first image pays the cold-start cost; subsequent images in the same session hit a warm container). Keep-warm strategies (periodic pings to maintain a hot container) were evaluated and rejected as an anti-pattern that incurs cost with no user benefit between sessions.

- **Summarisation (Together AI):** Review summarisation is a background Oban job. There is no user waiting for the result — freshness is measured in hours, not seconds. The 2–3 minute cold start is irrelevant here, and Together AI's per-token pricing is cost-effective for text-only inference.

**Configuration location:** `apps/core/config/config.exs`. Individual AI settings are stored under their respective service keys rather than a single `:ai` namespace. The following snippet is illustrative of the intent; refer to `config.exs` for the canonical form:

```elixir
# Illustrative — see apps/core/config/config.exs for actual keys
config :the_stacks, :ai,
  vision_model: "Qwen/Qwen2.5-VL-7B-Instruct",
  vision_provider: :modal,
  summarisation_model: "meta-llama/Llama-4-Scout-17B-16E-Instruct",
  summarisation_provider: :together_ai
```

**Model version pinning:** Models are pinned by name in config. The Qwen2.5-VL-7B-Instruct weights are downloaded to Modal's volume at `modal deploy` time. A production upgrade process requires:
1. Pinning to a specific HuggingFace commit SHA
2. Running the vision benchmark suite (Issue #005) against the new model
3. Only upgrading if accuracy is maintained or improved

See `docs/technical-architecture.md` section 5 (AI Safety & Guardrails) for the full model version pinning process.

---

## Consequences

**Positive:**
- Interactive upload flow remains responsive — Modal's 15–30s cold start is absorbed by the first upload in a session.
- User-uploaded photos are processed inside Modal's isolated GPU container — no data forwarded to Alibaba or any external AI API after deployment.
- Summarisation costs stay low via per-token Together AI pricing for background jobs.
- Two providers means no single vendor lock-in for all AI capabilities.

**Negative:**
- Two AI providers to manage, monitor, and rotate secrets for.
- Modal's cost model (per-second GPU time) is less predictable than per-token for variable-length inference.
- `VISION_HMAC_SECRET` must be provisioned as both a Fly.io secret (for the Phoenix core) and a Modal secret (for the vision service) and kept in sync.
- If Modal has an outage, photo-based book addition is unavailable until recovery. Manual ISBN entry remains functional. See `docs/runbooks/modal-outage.md`.

**Supply chain risk (documented):**
- Qwen model weights are downloaded by name from HuggingFace — a compromised repo could introduce different weights at next deploy. Mitigation: pin to a specific commit SHA and verify post-download.
- `requirements.txt` uses `>=` bounds — a transitive dep update could change behaviour. Mitigation: switch to exact pins (`==`) or use `pip-compile`.

**Budget controls:**
- `Stacks.AI.BudgetTracker` enforces daily (R5) and monthly (R50) caps on Modal spend.
- If budget is exhausted, Oban vision jobs snooze for 1 hour. Manual ISBN entry remains available.
- See `docs/runbooks/budget-exhaustion.md`.
