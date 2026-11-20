# US-1.1.16 — Uploads Queue Honestly When the GPU Is Saturated

## 1. User Story

> **As a** reader uploading during a busy moment, **I want** my photo to queue with an honest
> wait rather than fail **so that** a burst of readers degrades to patience, not to errors.

**Status: future-spec** (recorded 2026-11-20 from the absence pass; not yet built).

**The gap, cited.** Core's vision queue concurrency and the GPU class's container limits are
configured independently (`config.exs` queue concurrency vs `modal_app.py` container cap) with
a ~2:1 oversubscription and no handling story: no explicit queue-depth signal, no shed/backoff
policy, no reader-facing state for "many people are uploading right now".

**Acceptance criteria (when built):**
- The oversubscription ratio is a recorded decision with a measurement behind it.
- Saturation surfaces as queue position / expected wait on the existing stream, reusing the
  US-1.1.14 honesty affordances.
- A capacity breach alerts the owner before readers time out; the SLO gate carries the
  threshold.

## 2. Validation (when built)

- A load test at > container-cap concurrency; the SLO gate's planted-red pattern for the new
  threshold.
