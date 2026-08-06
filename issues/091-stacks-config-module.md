# Issue #091: Stacks.Config Module

## Summary
Centralise `:core` application-config lookups behind a single `Stacks.Config` module — both the **client/behaviour swaps** (`Application.get_env(:core, :some_client)`) and the **scalar knobs** (timeouts, limits, URLs, feature booleans) that are read the same ad-hoc way.

## Goal
Config wiring is currently invisible: **60 distinct `:core` keys are read across 94 `Application.get_env` call sites in 47 modules** (measured 2026-08-06), with the default value repeated at each site. Two problems follow.

1. **No inventory.** Nothing lists what is configurable, so nothing can check that a key is declared, documented, or reachable. Wave 10 found **25 env vars the code reads that `.env.example` never declared** — closed by hand in that wave, which fixes the symptom and leaves the cause.
2. **Inconsistent read paths for the same class of knob.** `RATE_LIMIT_AUTH` and `RATE_LIMIT_PASSWORD_CHANGE` are applied in `StacksWeb.Plugs.RateLimiter`'s GenServer `init/1` (`rate_limiter.ex:239-250`) with the comment *"runtime.exs runs before Fly.io secrets are injected into the process environment"*; `RATE_LIMIT_PUBLIC` and `RATE_LIMIT_E2E_HELPER` are read in `config/runtime.exs:66-75` instead — yet `scripts/deploy-stack.sh:926-927` stages both as Fly **secrets**. Either that comment is wrong (and the `init/1` re-application is redundant) or the preview's `RATE_LIMIT_PUBLIC=5000` / `RATE_LIMIT_E2E_HELPER=5000` overrides never take effect. One knob class must not have two contradictory answers.

A single module makes the surface enumerable, so "is this key declared and does it arrive?" becomes answerable by a test rather than a grep.

## Scope Check
Phased, because the whole surface exceeds one issue's budget (60 keys / 94 call sites).

- **Phase 1 — clients (the original scope).** 1 new module + ~14 keys + the modules that read them. ~80 LOC net.
- **Phase 2 — scalar knobs.** ~46 keys across the remaining call sites. **Likely needs its own issue** — split by domain (rate limits + lockout, timeouts, URLs/paths, feature booleans, secrets) if it lands over ~300 LOC. Requirement 5 is the part that must not be deferred: it resolves a live contradiction, not a style point.

## Technical Requirements

1. Create `Stacks.Config` with one function per key, each wrapping `Application.get_env(:core, :key, Default)` so the default lives in exactly one place.
2. **Phase 1 — client/behaviour lookups.** Replace every direct client lookup: `storage/0`, `vision_client/0`, `together_client/0`, `scraper_client/0`, `brave_client/0`, `searxng_client/0`, `isbn_http_client/0`, `geocoder/0`, `rss_fetcher/0`, `dbt_runner/0`, `feed_cache_writer/0`, `transparency_prometheus_client/0`, `argon/0`, plus the two test-override maps (`test_handler_overrides`, `circuit_breaker_probe_overrides`).
3. **Phase 2 — scalar knobs.** The remaining ~46 keys, by group:
   - **Limits / thresholds:** `rate_limit_auth`, `rate_limit_public`, `rate_limit_admin`, `rate_limit_password_change`, `rate_limit_e2e_helper`, `rate_limiting_enabled`, `login_lockout_threshold`, `login_lockout_window_seconds`, `login_lockout_duration_seconds`, `login_lockout_max_duration_seconds`, `login_lockout_backoff_window_seconds`, `public_shelf_cap`, `enrichment_confidence_threshold`, `slow_query_threshold_ms`, `modal_cost_per_call_cents`.
   - **Timeouts / intervals:** `identify_attempt_timeout_ms`, `sse_max_timeout_ms`, `geocode_throttle_ms`, `argon2_checkout_timeout_ms`, `metrics_push_interval_ms`.
   - **URLs / paths:** `vision_service_url`, `scraper_service_url`, `searxng_url`, `nominatim_base_url`, `together_ai_base_url`, `metrics_push_url`, `metrics_query_url`, `r2_bucket`, `r2_endpoint_host`, `upload_dir`, `dbt_dir`, `email_from`.
   - **Feature booleans:** `age_gating_enabled`, `smoke_tests_enabled`, `persistent_cache_enabled`, `isbn_resolver_cache_enabled`, `title_search_cache_enabled`, `lazy_price_refresh`, `validate_event_payload_contract`.
   - **Secrets:** `metrics_scrape_token`, `scraper_hmac_secret`, `vision_hmac_secret`, `google_books_api_key`, `brave_search_api_key`, `vision_together_api_key`. Accessors only — do NOT log or inspect these, and keep them out of any dump/inventory output.
   - `env` stays where it is if it is a compile-time discriminator rather than a knob.
4. Do NOT move config *values* — `config/*.exs` and `config/runtime.exs` remain where values are set. This issue moves only the **lookup**.
5. **Resolve the runtime.exs-vs-GenServer-init asymmetry** for env-sourced scalars (see Goal ▸ 2). Establish one rule for when a knob may be read in `runtime.exs` and when it must be read after secret injection, apply it to all five `rate_limit_*` keys, and record the rule in `Stacks.Config`'s moduledoc. If the `rate_limiter.ex:239` comment turns out to be stale, delete it and the redundant `init/1` block; if it is right, the two `runtime.exs`-only knobs are broken on Fly and must move.
6. `Stacks.Config` must expose an enumerable inventory of its keys (e.g. `all_keys/0`) so a test can assert every env-sourced key is declared in `.env.example` — turning the Wave 10 hand-fix into a standing gate. Adding a knob without declaring it should fail CI.

## Definition of Done
- [ ] All client lookups go through `Stacks.Config`
- [ ] No direct `Application.get_env(:core, …)` for client modules remains (grep proof)
- [ ] Scalar knobs migrated (Phase 2, or split out with its own issue number recorded here)
- [ ] Requirement 5 resolved — one documented rule, all five `rate_limit_*` keys following it, evidence that a preview override actually takes effect (not just that it is set)
- [ ] `all_keys/0` inventory exists and a test asserts env-sourced keys are declared in `.env.example`
- [ ] No secret value reachable through any inventory/dump path
- [ ] All existing tests pass
- [ ] `just run just verify` passes

## Dependencies
Suggested in Wave C retro, still unimplemented. Re-scoped 2026-08-06 (Wave 10) after the `.env.example` set-difference audit; the 25 undeclared keys were closed by hand in that wave, and Requirement 6 is what stops them coming back.

## Agent Assignment
elixir-agent
