# US-1.1.15 — A Canary Photographs a Book in Production

## 1. User Story

> **As the** platform owner, **I want** a scheduled canary that exercises the real
> identification loop in production **so that** "uploads are broken" is something the platform
> tells me before a reader does.

**Acceptance criteria:**
- The canary drives the production seam (not a mock), on a schedule, with its own account.
- Its GPU spend is attributed and bounded — a canary that silently costs real money is itself
  a defect (its spend shows up in the US-1.1.13 figures).
- Its failure is loud and distinguishable from provider blips.

## 2. Current State

- `scripts/probe-production.sh` exists and drives GPU spend (`modal_app.py` notes it), and the
  deploy seeds a prober account — BUILT, previously storyless; this story records the contract
  it must keep. Attribution of its spend falls out of per-app day-bucket billing (#588's
  measurement-app exclusion pattern applies to it explicitly).

## 3. Validation

- The probe script's own checks; spend attribution via the billing loop.
