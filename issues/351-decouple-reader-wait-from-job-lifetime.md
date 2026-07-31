# Issue #351: The reader waits for the job's whole retry budget

## Summary
Raised by the owner on 2026-07-31, on seeing that #342 derived the SSE deadline from actual job death: *"what is the operational impact of this? should we be investigating terminating the job earlier to tighten this down?"*

The investigation's answer: the deadline itself is近 inert — but the reader's *experience* is coupled to the job's full retry budget, and that is the thing worth changing.

Today `UploadController` sets the SSE deadline from `IdentifyBookJob.worst_case_lifetime_ms/0` = 3 attempts × 450s + 36s backoff ≈ **23.1 minutes** (and #350, if it raises the client timeout, pushes this toward ~35 minutes). The stream stays open across Oban retries, so a reader whose upload hits repeated *transient* failures watches an undifferentiated spinner for as long as the job keeps trying.

## What is NOT the problem
- **The deadline is a ceiling, not a wait.** #342's terminal guarantee broadcasts the moment the job dies, so a genuinely failed upload surfaces in seconds. The 23 minutes only elapses when the job neither completes nor dies catchably — essentially node loss, which Oban's stager already rescues.
- **Shortening the deadline is the wrong lever.** It would time the reader out while the job is still legitimately working — which is exactly the bug the old hardcoded 360s had.

## Goal
The reader's wait is bounded by what is worth waiting for, not by the worker's retry budget. A slow upload tells the reader what is happening; it does not present as a frozen spinner.

## User Stories
US-1.1.1 (upload failure UX), US-1.1.3 (photo → book).

## Scope Check
One controller's deadline policy + the SSE contract + the Elm upload page's state. At the bar — if the notification half (below) is chosen, split it.

## Wiring
Router wiring: uses the existing SSE stream; user-facing on completion.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops | Current behaviour | Verdict | Resolution |
|-----------|------------------|-------------------|---------|------------|
| US-1.1.1 a slow upload keeps the reader informed | SSE open for `worst_case_lifetime_ms` | undifferentiated spinner across all 3 attempts | 🟡 | fix in-scope |

## Technical Requirements
1. **Decide the policy first**, and record the reasoning. Two shapes, not mutually exclusive:
   - **(a) Tell the truth while waiting** — surface a distinct "still working / retrying" state after attempt 1 fails, so the spinner stops implying "nearly there". Cheapest; keeps the current guarantee intact.
   - **(b) End the reader-facing wait early** — stop the SSE wait after attempt 1 (~7.5 min) while Oban keeps retrying in the background, and notify on completion. Better experience; needs a notification path and a way to reattach, so it is materially more work.
2. **Do not weaken #342's terminal guarantee.** Whatever the reader sees, every job exit must still leave the image row terminal. `identify_book_job_terminal_test.exs` must stay green — and if (b) is chosen, a background completion must still reach the reader or the row's terminal state is invisible to them.
3. **Attempt state must reach the client honestly.** If the UI claims "retrying", that must be driven by real attempt data on the wire, not a client-side timer guessing.
4. **Live-drive it.** Force a transient failure on a preview and watch the reader's screen through a retry. A state machine that looks right in a program test is not evidence here; the whole issue is what the waiting *feels* like.

## Reviewer Context
- ⚠️ **#342's derivation is correct and should not be reverted.** The old hardcoded 360s expired while jobs were still legitimately running — that was the bug. This issue changes what the reader waits for, not how the job's death is computed.
- ⚠️ The SSE decoder is **strict** since #328 (six required snake_case fields); adding a field to the stream means updating `Api.elm`'s decoder and the proto together, and heartbeat frames deliberately fail decode and fall to the ignore branch.
- ⚠️ Modal is available, so a real transient failure can be forced on a preview.
- If (b) is chosen, the notification path is a new surface with its own consent/GDPR questions — scope it separately rather than absorbing it.
- Related: **#342** (terminal guarantee, the derivation), **#349** (latency data), **#350** (the timeout inversion that moves the ceiling).
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm | yes | ❌ the retrying state renders from real attempt data; program test drives it |
| Oban jobs | yes | ❌ #342's terminal guarantee still holds — existing suite green, cited |
| SSE / wire | yes | ❌ any new frame decodes strictly; heartbeats still ignored |
| Live drive | yes | ❌ a forced transient failure watched through a retry on preview — screenshots |
| Others | no | n/a |

## Definition of Done
- [ ] Policy chosen with reasoning recorded — evidence: the decision
- [ ] Reader sees an honest state during retries — evidence: program test + screenshots
- [ ] #342's terminal guarantee unbroken — evidence: `identify_book_job_terminal_test.exs` green
- [ ] Live-driven through a real retry on preview — evidence: screenshots + logs
- [ ] `staff-review` verdict recorded below

## Dependencies
Related to **#342** (built the derivation), **#349**, **#350** (both move the ceiling this issue makes tolerable). Needs an owner wave assignment — and a policy decision (a) vs (b) before build.

## Agent Assignment
elm-agent + elixir-agent.

## Progress Notes
Filed 2026-07-31 by the lead, from the owner's question on #342's SSE derivation. Numbers verified from source: `attempt_timeout_ms = 2 × 210_000 + 30_000 = 450_000`; `backoff/1` deterministic (jitter deliberately removed so the bound is a bound); worst case `3 × 450_000 + 36_000 = 1_386_000 ms`.
