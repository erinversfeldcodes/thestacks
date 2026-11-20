# US-1.1.14 — A Cold Start Waits Honestly

## 1. User Story

> **As a** reader whose upload happened to wake a cold GPU, **I want** an immediate
> acknowledgement and a truthful wait **so that** a thirty-second identification feels like a
> working system taking its time, not a broken one.

**Why this is a story.** Scale-to-zero (US-1.1.12) makes cold starts a deliberate trade; this
story is the other half of that trade: the reader-facing honesty that makes ~30 s acceptable.
The ruled thresholds: time-to-acknowledgement < 1 s, p50 ≤ 5 s, warm p95 ≤ 10 s, cold p95 ≈ 30 s
accepted and shown, never frozen.

**Acceptance criteria:**
- The upload stream's FIRST event is the current state, sent immediately on connect — the
  acknowledgement is a measurable server-side number, not a client-side impression.
- The waiting view stops promising imminence: a leave-safe note, a stream-silence watchdog,
  and an inbox for answers that finish in the reader's absence.
- No keep-warm pings: the plan's old self-contradiction is resolved BY RULING in favour of
  honest cold waits (the cost architecture decision), and the thresholds are wired as gating
  SLIs with planted-red proof.

## 2. Current State (delivered)

- First-event acknowledgement shipped 2026-11-19 (`upload_controller.ex`; the stream used to
  open silent); real-path emit test + probe.
- Waiting-view honesty (leave note, watchdog, inbox) shipped earlier; the retry stream now
  opens only after a rejection has landed, so it can never replay the just-rejected answer.
- The four thresholds are SLIs in `scripts/check-slo-gate.sh` (warm/cold split from dispatch
  records), each with a planted-violation red run in the platform harness.

## 3. Validation

- `upload_controller_test.exs` (first-event ack; telemetry emit), `check_slo_gate_test.sh`
  (60/0 incl. four planted reds), the live drive of 2026-11-20 end-to-end.
