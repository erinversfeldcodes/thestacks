# Issue #052c: dbt Data Quality Models + Incremental Materialisation

## Summary
Add data quality monitoring models and tune hot-path marts for incremental materialisation with 5-minute refresh latency.

## User Stories
N/A — data quality and performance tuning.

## Goal
Data quality is tracked across the enrichment pipeline. Hot-path marts refresh incrementally for low-latency reads.

## Scope Check
- 4 data quality dbt models
- Incremental config on 2-3 existing mart models
- ~200 lines SQL + YAML

## Wiring
- [x] This issue is implementation only.

## Technical Requirements

### Data Quality Models
1. `int_source_health` — source health status aggregation from `stg_source_health_checks`
2. `mart_data_quality_trend` — 12-week rolling window of data quality metrics (incremental)
3. `mart_enrichment_gaps` — books missing prices, reviews, or cover images
4. `mart_llm_faithfulness` — confidence distribution for LLM-generated content (review summaries, blog associations)

### Incremental Materialisation
- `mart_community_read_count` — incremental merge on book_id, only recompute changed placements
- `mart_platform_searchable` — incremental merge on book_id, only add new/changed books
- `mart_data_quality_trend` — incremental append with 12-week retention

### Configuration
- Add `+materialized: incremental` config for incremental models
- Configure merge keys and unique keys
- Add full-refresh escape hatch (`dbt run --full-refresh --select model_name`)

## Definition of Done
- [ ] Data quality models run and test correctly
- [ ] Incremental models produce correct results on both initial and incremental runs
- [ ] Full-refresh escape hatch works
- [ ] schema.yml entries with tests for all new models
- [ ] `just verify` passes

## Dependencies
- Issue #052a (core models — must exist)
- Issue #068 (source health data — complete)

## Agent Assignment
database-agent

## Progress Notes
