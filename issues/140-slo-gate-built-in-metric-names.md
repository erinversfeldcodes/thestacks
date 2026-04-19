# Issue #140: SLO gate parser expects wrong names for PromEx built-in metrics

## Summary
After Issue #139, the SLO gate's custom `stacks_*` metrics are correctly exported. But the gate's parser also reads PromEx built-in metrics (BEAM memory, Ecto queue_time, Phoenix endpoint duration) under names that don't exist in PromEx's actual output. These SLIs report `value=0` in production and false-pass every threshold check.

## User Stories
N/A (platform).

## Goal
Every SLI the gate checks reflects a real production signal. No more 0-value false passes.

## Root cause

PromEx's built-in plugins (`Plugins.Beam`, `Plugins.Ecto`, `Plugins.Phoenix`, etc.) produce metric names with a `<otp_app>_prom_ex_<plugin>` prefix. For this project with `otp_app: :core`, that's `core_prom_ex_`.

Confirmed via live scrape in test env:
- `core_prom_ex_beam_memory_atom_total_bytes` (plus `_binary_`, `_code_`, `_ets_`, `_processes_`, etc.)
- PromEx does NOT emit a unified `beam_memory_total_bytes` — memory is broken down per-category only
- Ecto plugin likely emits `core_prom_ex_core_repo_query_queue_time_milliseconds_*` (confirmed in docs; not spot-checked live but consistent with the observed prefix pattern)

The parser in `scripts/check-slo-gate.sh` expects:
- `beam_memory_total_bytes` (line 252, 498)
- `core_repo_query_queue_time_milliseconds_bucket` (line 246, 483)
- `phoenix_endpoint_stop_total` (line 241)

None of these match PromEx's actual output. Every SLI derived from these reports 0.

## Technical Requirements

### Parser corrections

Update `scripts/check-slo-gate.sh` metric name constants to match PromEx's actual output:

```python
# Before
"beam_memory_total_bytes"
# After
# BEAM memory — PromEx breaks this down per-category; sum them for the total.
["core_prom_ex_beam_memory_atom_total_bytes",
 "core_prom_ex_beam_memory_binary_total_bytes",
 "core_prom_ex_beam_memory_code_total_bytes",
 "core_prom_ex_beam_memory_ets_total_bytes",
 "core_prom_ex_beam_memory_processes_total_bytes",
 "core_prom_ex_beam_memory_persistent_term_total_bytes"]
```

And the `beam_memory_bytes` SLI computation:

```python
beam_bytes = sum(
    r["value"]
    for metric_name in BEAM_MEMORY_METRICS
    for r in rows_for(metric_name)
)
```

Similarly for Ecto queue_time — confirm the actual metric family name by doing a live scrape of the prod app:

```bash
curl -sS -H "Authorization: Bearer $METRICS_SCRAPE_TOKEN" \
  https://thestacks-core.fly.dev/internal/metrics \
  | grep -E '^(#|)(core_prom_ex_)?(beam|core_repo|phoenix)' \
  | head -80
```

Capture the output, add it as a fixture, and update the parser + fixture-based tests to match.

### Fixture refresh

Hand-written fixtures in `test/fixtures/metrics/` use the wrong names. Regenerate by:

1. Running `PromEx.get_metrics(Core.PromEx)` in a test or dev session.
2. Saving a representative scrape (healthy state) as `test/fixtures/metrics/prom_sample_healthy.txt`.
3. Editing a copy to force specific threshold breaches (`prom_sample_breached_latency.txt`, etc.) so the existing test cases keep exercising breach/pass logic.

Bonus: the existing fixture format may not match PromEx's real output (label ordering, comment lines, end-of-file newline handling). The refreshed fixtures become the new source of truth.

### Gate assertion

Add a test to `test/platform/check_slo_gate_test.sh`:

```bash
test_case "real_scrape_produces_nonzero_beam" \
  "healthy real-scrape fixture yields non-zero BEAM memory"
# Assert jq ".slis[] | select(.name==\"beam_memory_bytes\") | .value" > 0
```

If this had existed, it would have caught the current bug before Issue #136 went live.

## Reviewer Context
- Parser is Python-in-bash-heredoc in `scripts/check-slo-gate.sh` — see lines ~200–550.
- Test fixtures live in `test/fixtures/metrics/`.
- Test harness is `test/platform/check_slo_gate_test.sh`.
- PromEx version: see `mix.lock`.

## Definition of Done
- [ ] Live scrape captured from prod; actual metric names documented.
- [ ] Parser constants in `scripts/check-slo-gate.sh` updated to match.
- [ ] BEAM memory SLI sums across per-category metrics.
- [ ] Ecto queue_time parser uses the correct prefix + full name.
- [ ] Fixtures in `test/fixtures/metrics/` refreshed from real scrapes.
- [ ] Platform test asserts non-zero BEAM memory on the healthy fixture.
- [ ] Running the gate against a real deploy produces non-zero values for every non-custom SLI.

## Dependencies
- Issue #139 (custom stacks_* metric export) — merged first. #140 completes the "gate sees real values" picture.

## Agent Assignment
platform-agent (parser + fixtures + tests).

## Progress Notes
2026-04-19: Filed after Issue #139's live verification confirmed the custom-metric half is correct but surfaced a parallel bug in built-in metric naming. Together with #139, fully closes the SLO-gate false-pass gap.
