# Issue #066: Backup & Restore Verification

## Summary
Document and verify the backup/restore procedure for all stateful services: Neon PostgreSQL, Cloudflare R2 (images), and Fly.io machine state. Write a runbook that can be followed by someone who isn't the original developer. Perform a restore drill to verify the procedure works.

## User Stories
Cross-cutting — operational resilience for all stories.

## Goal
If the production database is lost, a documented procedure exists to restore it within a defined RPO (Recovery Point Objective) and RTO (Recovery Time Objective). The procedure has been tested at least once.

## Technical Requirements

**Neon PostgreSQL backup/restore:**
- Document Neon's automated backup capabilities (point-in-time recovery, branch snapshots)
- `docs/runbooks/neon-restore.md` — step-by-step: (1) create restore branch from point-in-time, (2) verify data integrity, (3) update `DATABASE_URL` in Fly.io secrets, (4) restart core app, (5) verify application health
- RPO target: < 1 hour (Neon PITR granularity)
- RTO target: < 30 minutes (branch creation + secret update + restart)
- Test: create a Neon branch from 1 hour ago, connect a local instance, verify data is present and consistent

**R2 backup/restore:**
- Document R2's built-in durability (11 9's) and whether cross-region replication is enabled
- For uploads (ephemeral, 30-day TTL): loss is acceptable — images are transient by design
- For covers (permanent): document re-fetch strategy — covers can be re-sourced from Open Library/Google Books. No backup needed.
- For marketplace photos: these are user-generated and irreplaceable. Document whether R2 versioning is enabled. If not, recommend enabling it.
- `docs/runbooks/r2-data-loss.md` — impact assessment per prefix, recovery steps

**Fly.io machine state:**
- Fly machines are ephemeral — no persistent state (DB is in Neon, images in R2)
- Document that machine loss is a non-event: `fly deploy` recreates everything
- Document secret recovery: secrets are in Fly.io, not on the machine. If Fly.io account access is lost, secrets must be re-provisioned from `.env` backup.

**Event log integrity:**
- `op.event_log` is append-only and immutable. Verify that a restored database preserves the full event log.
- Test: count events before and after restore — must match exactly.

**Restore drill procedure:**
1. Take note of current state: user count, book count, event count, latest `event_log.occurred_at`
2. Create Neon restore branch from 1 hour ago
3. Connect local app to restore branch
4. Verify: user count matches, book count matches, event log is intact
5. Run `dbt run` against restored data — verify marts rebuild correctly
6. Document results in `docs/runbooks/restore-drill-results.md`

## Definition of Done
- [ ] `docs/runbooks/neon-restore.md` exists with step-by-step procedure
- [ ] `docs/runbooks/r2-data-loss.md` exists with impact assessment per prefix
- [ ] RPO < 1 hour, RTO < 30 minutes documented and achievable
- [ ] Restore drill performed against a Neon branch — results documented
- [ ] Event log integrity verified post-restore
- [ ] dbt marts rebuild correctly against restored data
- [ ] Marketplace photo backup strategy documented (R2 versioning recommendation)
- [ ] `docs/runbooks/restore-drill-results.md` committed with drill outcomes

## Dependencies
Issue #064 (R2 must be in use for R2 backup assessment to be meaningful). Issue #063 (production deployment must exist for drill).

## Agent Assignment
platform-agent + principle-engineer-agent

## Progress Notes
