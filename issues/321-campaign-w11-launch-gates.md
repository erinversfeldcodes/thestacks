# Issue #321: [EPIC] Campaign Wave 11 — Launch gates

## Summary
Epic for Wave 11 of `plans/staff-campaign-2026-07-30.md`: the net-new launch features (Milestones B–D), the prod deploy, and — per owner ruling 2026-07-30 — **wiring the bookstore-events vertical** rather than deleting it. Mostly re-points existing backlog items at the new stories from #320.

## User Stories
New stories from #320 (invite-only, Goodreads CSV, POSSE, FAQ, feedback) + US-2.4.1 (bookstore events, refreshed) + US-14.4.x interplay + #163/#066 runbooks.

## Goal
Registration is invite-gated; an invited user can import their Goodreads library; posts syndicate outward with canonical links; the platform runs on a real production domain with verified backups and a feedback channel; bookstore-event scraping produces real rows end-to-end.

## Scope Check
Epic; each feature is its own child (several are M/L alone — the orchestrator may split further).

## Wiring
Router wiring: new endpoints per child (register gating, CSV import, events read path) — each child states its own.

## Feature-Completeness Pre-Check
Baseline all ❌ by construction (net-new features); each child's pre-check fills at spin-out against its #320 story.

## Technical Requirements (child phases)
1. **Invite-only registration**: allowlist/invite-code gate on `POST /auth/register`; owner issues invites; open-registration path retired per the story; no-enumeration preserved.
2. **Goodreads CSV import**: CSV parse (title/author/ISBN/shelves/ratings/dates) → **through the ISBN hard gate** (import is just another capture source; junk still can't enter) → bookshelves + read/unread + placement history; provenance "imported from Goodreads"; one-directional; per-row failure report to the user.
3. **POSSE/Substack MVP**: canonical-tagged export + RSS-import route per the story (no write API exists — the constraint IS the design); `rel=canonical` back-links.
4. **Bookstore-events vertical (owner ruling)**: cron entry for `DiscoverBookstoreEventsJob`; replace the raw-regex extractor with the structured path (schema.org/Event → `.ics` → LLM fallback, per the research doc; egress via the compliant scraper path from the prior campaign's Wave 0c/0d); read endpoint from `Enrichment.Events`' currently-unused functions; surface events (book detail author section currently says "Events coming soon"); `op.bookstore_events` goes 0 → real rows on preview (zero-row sweep is the acceptance instrument).
5. **Prod deploy + safety floor**: execute #163's runbook on the real domain; backup/restore verification per #066; beta feedback channel (lightweight form/email per story).

## Reviewer Context
- The ISBN hard gate is non-negotiable for the importer — no CSV row creates a book without verification; unresolvable rows are reported, not silently dropped (structurally-valid-but-false lesson).
- Bookstore-events: the shared `:scraper_fuse` semantics (proto `scraper.proto:230-239`) apply — event scraping must not melt the price path's fuse; the LLM fallback needs cost caps (Milestone E discipline) and inherits #314's enum-coverage gate.
- Invite-gating changes `register.spec.ts`/`auth.setup` expectations — the E2E fixture path must mint via the test helper, not open registration.
- `min_machines_running = 0` (ROOT H): the events cron only fires while a node runs — the child must state how it actually runs in prod (accepting freshness-only cost, or the read-time/event-driven alternative), not just add a crontab line.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| API/auth | yes | ❌ gate: invited 201 / uninvited generic refusal; importer row outcomes |
| Oban/external | yes | ❌ events job: structured extract on fixture pages; fuse isolation; zero-row sweep 0→N on preview |
| E2E | yes | ❌ invite journey; import journey (fixture CSV); syndication export check |
| Ops | yes | ❌ backup restore drill evidence; prod smoke on real domain |
| Others | n/a epic-level | per child |

Punch: 8 items.
Verdict: baseline ❌ ×8.

## Definition of Done
- [ ] Each feature driven live: uninvited registration refused, invited succeeds; a real Goodreads CSV imports with per-row report; a post exports with canonical link; bookstore events render from scraped rows — evidence: screenshots + row counts
- [ ] Zero-row sweep: `op.bookstore_events` > 0 on preview via the real job (not seed) — evidence: SQL + job log
- [ ] Prod domain serves; backup restore drill completed — evidence: runbook artifacts
- [ ] Feature-Completeness per child ✅ live; validation paths; suites + `just verify` + `just ci`; audit GREEN; `completion-audit`; Completion Bar
- [ ] `gdpr-review` on importer + events diffs (new personal data: import provenance; external data classification for events) — cite verdicts
- [ ] `staff-review` per child in Progress Notes

## Dependencies
- #320 — the stories these features implement. Reason: spec before build.
- #311 (0d) + #314 (enum gate) — the events job consumes the scrape-outcome contract. Reason: contracts before consumers.
- #317 — invite-gating interacts with resend-confirmation/registration copy. Reason: one registration surface, sequenced edits.

## Agent Assignment
Orchestrator; elixir-agent, elm-agent, scraper/rust agent (events extractor), ops for deploy children.

## Progress Notes
Filed 2026-07-30 by staff-campaign Stage 7. Owner ruling embedded: bookstore-events wired, not deleted.
