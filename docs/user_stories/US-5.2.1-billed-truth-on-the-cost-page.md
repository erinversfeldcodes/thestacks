# US-5.2.1 — The Cost Page Tells Billed Truth

## 1. User Story

> **As a** reader of the public cost page, **I want** each line to say whether it is a bill or
> an estimate, refreshed through the day, **so that** radical transparency is checkable against
> invoices.

**Status: foundation live; delivery tracked.** The pusher→VictoriaMetrics→`/costs` path exists
(daily); Modal's line reads measured billing. The full delivery — billed Modal MTD +
today-so-far at a 2–4 h cadence, provenance labels per provider, PENDING-never-$0 for unlanded
buckets, and per-PR cost attribution — is issues #587 and #588, filed 2026-11-20 with the
measured billing semantics baked into their DoDs.

**Acceptance criteria:** as #587/#588's DoDs state them (this story is their user-facing home;
the owning jobs are `push_billing_metrics.py` and `RefreshCostsJob`, with `op.platform_costs`
as the page's table — previously storyless, now owned here).
