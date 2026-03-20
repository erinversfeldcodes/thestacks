# Wave B Retrospective

**Branch:** feat/wave_b
**Date:** 2026-03-20
**Issues:** #046, #047, #048, #076, #077, #078, #079, #080

## Summary

Wave B delivered the visibility infrastructure, user settings/privacy controls, works/editions integration, and proto-to-schema codegen. 7 of 8 issues complete, 1 incomplete (#078 — ViewAsPlug router wiring deferred).

| Issue | Title | Status |
|-------|-------|--------|
| #046 | Core contexts for works/editions + two-step upload | Complete |
| #047 | Visibility infrastructure — resolve_visibility + blocks + property tests | Complete |
| #048 | Controller retrofit + settings endpoints + RLS | Complete |
| #076 | Block/unblock HTTP API endpoints | Complete |
| #077 | Profile visibility settings endpoint | Complete |
| #078 | ViewAsPlug ownership check for regular users | Incomplete |
| #079 | Community read count in book detail | Complete |
| #080 | Proto-to-schema codegen | Complete |

---

## What Worked

### Property-based testing for security-critical code
The 6-invariant × 200-run property test suite for `resolve_visibility/2` (#047) caught edge cases that unit tests would have missed. The investment in StreamData generators paid off — 1200 generated cases proved the visibility gate is sound. This pattern should be applied to other security-critical paths (GDPR erasure, rate limiting).

### Manifest-driven codegen (#080)
The decision to use `proto/persisted.exs` instead of custom proto options kept `.proto` files clean and made the codegen tool zero-dependency (no protoc plugin, no options.proto). The `buf build` JSON descriptor approach avoided writing a proto parser entirely.

### Small, focused issues (#076, #077, #079)
These single-endpoint issues were fast to implement, easy to review, and easy to verify. The block/unblock API (#076) took one commit. Compare with #048 (settings + RLS + controller retrofit) which was a large surface area in a single issue.

### Five-reviewer parallel review (#080)
Running elixir, database, protobuf, contract, and PE reviewers simultaneously caught issues across different axes. The timestamp column naming false positive (flagged by 3 reviewers, disproved by checking the Repo config) validated that independent reviewers surface the same concerns — even when wrong, the convergence was informative.

### Fresh database verification (#080)
Running `ecto.drop → create → migrate → seed → test` caught nothing (all green), but the confidence it provided was worth the 60 seconds. Should be standard practice before merge for any issue touching migrations or schemas.

---

## What Caused Friction

### The bootstrap problem (#080)
We spent significant time experimenting with build-time schema generation before discovering that Elixir's compilation model creates a circular dependency: generated schemas must exist before modules that reference their structs can compile, but the generator must be compiled first. The experiment produced a good ADR finding, but the time cost was real. **Lesson:** When considering "generate vs check in" for Elixir, always check for struct expansion dependencies first.

### Multi-table migration files (#080)
The `source_health_checks` table shares a migration file with 5 other marketplace tables. The initial column extraction regex grabbed columns from ALL tables in the file, producing 25+ spurious "column not in proto" warnings. Required a more sophisticated table-scoped regex. **Lesson:** Migration files are not 1:1 with tables. Any tool that parses migrations must scope to the target table.

### Reviewer false positives (#080)
Three of five reviewers flagged the same non-bug (timestamp column naming). They all missed the global Repo config at `config/config.exs` that renames `inserted_at` to `created_at`. This cost a review round. **Lesson:** Global configs that change framework defaults should be prominently documented (e.g., a comment in the config file that says "ALL timestamps() calls produce created_at, not inserted_at").

### Large issue scope (#048)
Issue #048 combined controller retrofit, 4 settings endpoints, visibility controls, and RLS policies into a single issue. It was the largest commit on the branch. Breaking it into 2-3 smaller issues would have made review easier. **Lesson:** If an issue touches more than 3 controllers or adds more than 2 new endpoints, split it.

### Issue #078 left incomplete
ViewAsPlug ownership enforcement was implemented but never wired into the router. The issue was functionally complete but not user-facing. This should have been flagged earlier as "done but not wired" rather than left in an ambiguous state. **Lesson:** Issues should be either fully complete (including router wiring) or explicitly marked as "implementation only, wiring deferred to X."

---

## What Should Change

### Add global config documentation
The `migration_timestamps: [inserted_at: :created_at]` setting in `config.exs` caused confusion across 3 reviewers. Add a prominent comment block in the config file listing all framework defaults we override and their effects. This prevents the same class of false positive in future reviews.

### Codify "fresh DB verification" as a gate
The `ecto.drop → create → migrate → seed → test → dbt` cycle should be a standard pre-merge gate for any issue that touches migrations, schemas, or dbt models. Add it to the orchestrator protocol as an optional gate (triggered when migration files are in the diff).

### Split large issues earlier
The #048 pattern (multiple concerns in one issue) made review harder and the commit larger than necessary. When scoping issues, apply the rule: one concern per issue, max 2 new endpoints, max 300 lines of production code.

### Proto codegen: track which tables have been synced
Currently `migration_exists: true/false` is a manual flag. If a developer adds a new table to the manifest but forgets to set `migration_exists: false`, no CREATE TABLE migration is generated. Consider auto-detecting this by scanning existing migrations for the table name.

### Document the "how to add a new table" workflow
The proto codegen has no step-by-step guide beyond the ADR and manifest file. Add a section to `docs/technical-architecture.md` with the 4-step workflow: write proto → add to manifest → run `mix proto.sync` → commit.

---

## Metrics

| Metric | Value |
|--------|-------|
| Issues completed | 7 of 8 |
| Total commits | 20 |
| Tests at branch tip | 697 tests + 15 properties |
| dbt tests | 165 |
| Test failures | 0 |
| Review rounds (#080) | 2 (5 reviewers each) |
| Review false positives | 3 (same issue, same root cause) |
