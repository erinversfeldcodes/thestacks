# Issue #320: [EPIC] Campaign Wave 10 — Documentation, stories, and the mapping

## Summary
Epic for Wave 10 of `plans/staff-campaign-2026-07-30.md`: make the story corpus, mapping, and notes trustworthy again — both staleness directions — and write the missing launch stories. Disposes the campaign's remaining 1c (absence-pass) obligations.

## User Stories
Meta — this epic creates/repairs the stories themselves.

## Goal
Every Phase 1 surface has an owning story; the mapping cites reality; the six self-denying stories are refreshed; the five launch-milestone intents are storied; deliberate exclusions are recorded IN the mapping so they stop resurfacing.

## Scope Check
Epic; children batched by artifact (mapping / story refreshes / new stories / notes+memory), documentation-only.

## Wiring
Router wiring: n/a — documentation.

## Feature-Completeness Pre-Check
n/a — documentation epic (its own verification is census re-runs).

## Technical Requirements (child phases)
1. **Mapping repairs**: map the 7 unmapped story files (US-1.6.1/2/3/6, US-1.7.1, US-14.4.1/2) into phase table + story-by-story sections; fix `implementation-mapping.md:1857` (AgeVerification/Export/Delete out, Privacy in) + the `:1221`/`:1241` self-contradictions + phantom `US-11.2.1` (`:2221`); fix `:698`'s eight nonexistent components + `:562`'s `Page.Upload.Review`; record deliberate exclusions (cancel-deletion grace, public photo-delete, age-gate Verify pointer, non-ISBN readables pointer) so audits stop re-raising them.
2. **Story refreshes (code is ahead of the doc)**: US-14.3.2 (refresh endpoint exists), US-10.2.1 (init hydration exists), US-8.5 (audit page exists + sidebar entry), US-2.5.3 (ListingRemoval page exists), US-6.1 (visibility ruling of 2026-07-29 + the handle-form feed URL — the only client-constructible form), US-14.4.1 (frontend fully built — rewrite the "not built" sections; also rewrite issue #191's stale summary to its real residue).
3. **New stories**: invite-only registration, Goodreads CSV import, POSSE/Substack cross-post, platform FAQ/About, beta feedback channel (Milestones B–D — #321 builds against these); undo-remove + owner-only un-merge (per 2026-07-30 rulings, for #317); shipped-unstoried clusters: transparency/insights (ADR-019/021 as spec-of-record or stories), admin-MFA surface, auth-hygiene jobs incl. the user-visible 24h unconfirmed-account erasure, `DiscoverEditionsJob`, catalogue page; re-scope US-2.1.1 reviews to sanctioned sources (D6); bookstore-events story refresh for #321 (extractor now structured, cron-driven).
4a. **From #323's staff-review (Wave 0)**: `MetricsAuth`'s 6PN bypass + `endpoint.ex:43`/`runtime.exs:120-126` comments still reference the retired Fly scrape; `scripts/dashboard-smoke.sh` targets the retired Fly Prometheus — clean up or delete alongside the runbook truth.
4. **Registry, notes, config, memory**: event-registry moduledoc stops claiming completeness (or the registry becomes complete — decided in #314; document here); correct `notes/phase-1-launch-extension.md:16-20`'s two stale proof points (PlacementCard + ShelfOrganiser are wired; the residue is US-1.7.1's move-between-shelves leg); document the 20 read-but-undeclared config keys (in `.env.example` or a config reference); re-scope #091 to include scalar knobs; project-memory corrections (Route.Settings IS producible — defect was the round-trip; onboarding dot off-by-one not reproducible in code).

## Reviewer Context
- Census pitfalls are load-bearing: stories live in TWO homes (per-file + narrative `user-stories.md`), two ID granularities; US-1.5.4 is deliberately file-less (mapping:813). Re-run the census AFTER edits as the exit check.
- No unilateral roadmap invention: new stories implement the owner's recorded rulings and the notes' milestones — anything discovered beyond that becomes a question, not a story.
- `notes/` is gitignored and absent in worktrees — notes edits happen in the main tree.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Census | yes | ❌ re-run the three-way census: 0 unmapped in-scope story files; 0 phantoms; 0 self-denying stories (spot-grep the six) |
| Links | yes | ❌ every cited `#NNN`/US-id resolves to a real file (the wave-status/no-phantom rule applied to docs) |
| 1–13 | no | n/a — documentation |

Punch: census re-run + citation sweep.
Verdict: baseline ❌ ×2.

## Definition of Done
- [ ] Census re-run clean (raw + reconciled shown) — evidence: command outputs
- [ ] All new stories written with experiential sections where user-facing (the Register-A discipline) — evidence: file list
- [ ] Six refreshed stories no longer deny shipped code — evidence: grep per claim
- [ ] Exclusions recorded in mapping — evidence: diff
- [ ] #191 summary rewritten; #091 re-scoped — evidence: diffs
- [ ] `completion-audit` passed; `staff-review` per child in Progress Notes

## Dependencies
- #314 (registry decision), #317 (ruling stories) — content lands as those waves decide it; mapping-repair child (phase 1) can start immediately. Reason: record decisions, don't pre-empt them.
- The **US-14.1.2 / US-15.1.1 / US-18.1.1** amendments were **pulled forward into #387** (owner decision 2026-08-05) so Wave 8 builds against a settled spec; #320 treats them as already-written and only re-checks them in the exit census. Reason: spec-before-build won over record-after for the surfaces #318 rebuilds.
- Precedes #321 — its features build against these stories. Reason: spec before build.

## Agent Assignment
Orchestrator; docs-focused children; owner reviews new story files.

## Progress Notes
Filed 2026-07-30 by staff-campaign Stage 7.
