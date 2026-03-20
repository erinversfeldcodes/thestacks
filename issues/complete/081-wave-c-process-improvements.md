# Issue #081: Wave C Process Improvements

## Summary
Codify lessons from Wave A and Wave B retros into actionable tooling, documentation, and workflow changes before starting Wave C work.

## User Stories
N/A — internal process improvement.

## Goal
Reduce friction, eliminate repeat mistakes, and accelerate future issue cycles by addressing every process gap identified in the Wave A batch retro (026-039) and Wave B retro.

## Technical Requirements

### 1. Global config documentation
Add a prominent comment block to `apps/core/config/config.exs` listing every framework default we override and its effect. At minimum:
- `migration_timestamps: [inserted_at: :created_at]` — all `timestamps()` calls produce `created_at`, not `inserted_at`
- `migration_primary_key: [type: :binary_id]` — all tables get UUID primary keys
- `generators: [binary_id: true, timestamp_type: :utc_datetime_usec]`

### 2. `just verify` recipe
Add a single justfile recipe that runs the full pre-merge gate:
```
verify: lint-elixir test-elixir lint-proto proto-sync-check test-dbt lint-dbt
```
One command for "is this branch ready to review?"

### 3. Proto sync in stop hook
Add `mix proto.sync --check` to the Claude Code stop hook in `.claude/settings.json` so drift is caught on every response, not just at CI time.

### 4. Issue template update
Update `issues/TEMPLATE.md` to include:
- **Scope limit guidance**: "If this issue touches >3 controllers or adds >2 new endpoints, split it."
- **Wiring criterion**: "Does this issue include router/UI wiring? If not, specify which issue wires it."
- **Reviewer context section**: "List non-obvious project conventions reviewers need to know."

### 5. Reviewer context in review prompts
Update the orchestrator review delegation to include:
- CI output (test results, credo, dialyzer) alongside the file list
- A "reviewer context" block with relevant project conventions

### 6. Fix lint-dbt.sh column checks
The agent-written versions of `schema.yml` and `sources.yml` were accepted but `lint-dbt.sh` still has the old `run_warn` calls with stale TODO comments. Verify the file on disk matches the promoted `run_check` versions.

### 7. Remove `my_writing_links` from sources.yml
The table was never created (deprecated in favour of `blog_posts` + `users.website_url`). Remove the phantom entry. (Note: may already be done — verify.)

### 8. Ban E2E soft-skips
Grep all E2E test files for `console.log.*skipping.*return` patterns. Any remaining instances must be converted to either:
- Precondition setup (via `ensureBookOnShelf` or similar helper), or
- Hard `expect().toBeDefined()` assertions

### 9. Fresh DB verification gate
Add to the orchestrator protocol (`docs/agents/orchestrator-agent.md`) an optional gate: "If the diff includes migration files, run `ecto.drop → create → migrate → seed → test → dbt` before requesting reviews."

### 10. Save process learnings to memory
Save key findings to the Claude Code memory system so future conversations benefit:
- Issue scoping rules
- Reviewer context convention
- `just verify` as the pre-review command

## Definition of Done
- [ ] `config.exs` has prominent comment block documenting all overridden defaults
- [ ] `just verify` recipe exists and runs the full pre-merge gate
- [ ] `.claude/settings.json` stop hook includes proto sync check
- [ ] `issues/TEMPLATE.md` updated with scope limit, wiring criterion, reviewer context
- [ ] `lint-dbt.sh` has all 8 checks blocking (no `run_warn` remaining)
- [ ] `my_writing_links` removed from `sources.yml`
- [ ] Zero E2E soft-skip patterns remain (`console.log.*skipping.*return`)
- [ ] Orchestrator agent doc updated with fresh DB gate
- [ ] Process learnings saved to memory

## Dependencies
None — standalone process issue.

## Agent Assignment
Direct implementation (no specialist needed).

## Progress Notes
