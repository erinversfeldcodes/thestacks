# US-1.1.13 — The Cost Figures Come From Bills

## 1. User Story

> **As a** reader of the public cost page (and as the owner paying it), **I want** the platform's
> cost claims to come from what providers actually billed **so that** radical transparency means
> bills, not projections.

**Acceptance criteria:**
- Per-identification and monthly GPU figures trace to `modal billing report`, with the
  prediction-vs-bill gap stated when a model is used.
- A billing bucket that has not landed renders as PENDING, never as $0.
- Provider lines carry provenance: billed vs metered estimate.

## 2. Current State

- The audit exists (`docs/evidence/vision-cost-audit-2026-11-17.md`) and the billed-constant
  loop is live (US-1.1.12); the public page reads measured billing for Modal month-to-date.
- The remaining delivery — billed truth on the dashboards at a few-hour cadence with
  provenance labels, and per-PR cost attribution — is tracked as issues #587 and #588, filed
  2026-11-20 with the measured semantics (day buckets, ≲4 h lag, per-app isolation) baked in.

## 3. Validation

- #587's emit-and-scrape + pending-vs-zero planted tests; the money-unit lesson (assert at the
  scrape) applies to every new family.
