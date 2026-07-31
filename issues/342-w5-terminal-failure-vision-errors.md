# Issue #342: W5 child — No upload may end non-terminal, and vision errors become a closed set

## Summary
Child of epic #315, Level 1. `IdentifyBookJob` has an exit path (`identify_book_job.ex:125-128`) that leaves the `uploaded_images` row `pending` forever — the reader watches a spinner until `sse_max_timeout_ms` expires, long after the job is dead. Separately, vision failures are an open-ended term, so deterministic failures (an undecodable image) are retried on GPU exactly like transient ones (a circuit-open), burning budget to fail again.

## User Stories
US-1.1.1 (failure UX foundations).

## Goal
Every exit path of the upload pipeline leaves the image row terminal, the SSE timeout matches when the job actually dies, and a vision failure's *kind* decides whether it is retried — not its accident of shape.

## Scope Check
One worker + one client module + the Python sidecar's error codes. Two subsystems but one concern (failure truth). At the bar; if it grows, report rather than absorb.

## Wiring
Router wiring: none. User-visible as a failure state that arrives in seconds rather than minutes.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops | Live-drive result | Verdict | Resolution |
|-----------|------------------|-------------------|---------|------------|
| US-1.1.1 upload fails visibly | `IdentifyBookJob` → `mark_rejected/2` → SSE | a failure on the `:125-128` path never marks; UI spins to timeout | ❌ | fix in-scope |

## Technical Requirements
1. **Final-attempt wrapper (shape B first — it is the safety net).** No exit of `IdentifyBookJob` may leave the row `pending`. `mark_rejected/2` already exists and is idempotent, so the wrapper is safe to apply broadly. Write it as a wrapper rather than patching the one known gap: patching `:125-128` fixes today's bug, a wrapper fixes the class — and the class is what bit us.
2. **Align `sse_max_timeout_ms` with actual job death** (Oban max attempts × backoff), so the client's give-up time is derived from the job's, not guessed alongside it. If they cannot be derived from one source, say why in a comment.
3. **Closed vision error set (shape A):** `:circuit_open | :budget_exceeded | {:undecodable_image, _} | {:upstream_status, _} | {:transport, _}`. Mirror the pattern `ISBNResolver` already documents — read it first and follow it rather than inventing a second convention.
4. **Sidecar returns distinguishable codes** (`apps/vision`). Deterministic → `{:cancel, reason}` with a user-meaningful reason; transient → retry. An undecodable image must never be retried on a GPU.
5. **`image.rejected` is emitted on terminal failure.** Note `image.*` events are currently in `@unsubscribed` (#334) with a documented rationale — emitting is still correct; do not add a handler without a reason, and if you believe one is needed, say so rather than adding it silently.

## Reviewer Context
- BOOTSTRAP (worktree): `git merge --ff-only feat/campaign-w5-315` FIRST — LOCAL, UNPUSHED, no `git fetch`, no `origin/`. Copy `.env`; regenerate proto artifacts (rsync `apps/core/lib/stacks/gen/` from the main checkout first if `core` won't compile); copy `apps/core/assets/index.html` → `apps/core/priv/static/index.html` if `PageControllerTest` fails.
- **NEVER bare `mix`** — `just run mix …`. **`caffeinate -i`** for long runs. **NEVER `git checkout`** to revert a probe — use Edit + `grep -c`.
- ⚠️ **Proto enums are now CLOSED types with a build-failing coverage gate** (#334). If you add a vision error code to a `.proto` enum, `scripts/check-enum-coverage.py` will fail the build until every consumer handles it — that is intended. Run `bash scripts/lint-proto.sh` (FIVE codegen targets, not two).
- ⚠️ **`endpoint_path/1` in `Stacks.AI.Client` maps `"is_book"` → `/classify` and `"extract_isbn"` → `/extract`. The Python sidecar paths must NOT change** — only the Elixir mapping may.
- The steerable `MockClient` seam (#327) is how these tests exist at all — `put_response/2` keyed by endpoint, with `$callers` walking. Use it; do not write another ad-hoc mock (that is #331's whole job to remove).
- Preserve these existing good patterns: idempotent `mark_resolved`/`mark_rejected` scoping, telemetry PII whitelisting, `interpret/2`'s determination split.
- Modal deploy needed for the E2E leg — **Modal is unblocked as of 2026-07-26**; budget GPU cold start.
- Commit: agent commits are DENIED. Stage; ONE-LINE message to `/private/tmp/claude-501/-Users-erinversfeld-thestacks/78bc6659-34d4-45c2-b5b7-9a0337db2154/scratchpad/commit-msg-342.txt`. NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Oban jobs | yes | ❌ property-style: for EVERY error branch, the row ends terminal — probe by removing the wrapper |
| Oban jobs | yes | ❌ deterministic → cancel (no retry); transient → retry. Assert attempt counts, not just outcome |
| External services | yes | ❌ sidecar error-code contract test (Python + Elixir sides agree) |
| Event flow | yes | ❌ `image.rejected` emitted on terminal failure |
| Others | no | n/a |

## Definition of Done
- [ ] Final-attempt wrapper; zero-row sweep shows no `pending` rows after a full failure-mode sweep — evidence: SQL output
- [ ] SSE timeout derived from job death, or the reason it cannot be — evidence: diff + comment
- [ ] Closed error set with a catch-all that cannot silently swallow — evidence: type + test
- [ ] Deterministic failures not retried on GPU — evidence: attempt-count assertion
- [ ] `image.rejected` emitted — evidence: test name
- [ ] Mutation probe on the terminal guarantee — evidence: red transcript
- [ ] Suites green under `caffeinate` — evidence: counts
- [ ] `staff-review` verdict recorded below

## Dependencies
Epic #315. **Depends on #313** (the steerable vision seam is why these tests are writable). Level 1 — parallel with #341 (disjoint: worker/vision vs context). **Precedes #331** (which converts the remaining ad-hoc vision mocks) and #344 (which matches the closed error type).

## Agent Assignment
elixir-agent (worker) + vision/python agent (sidecar codes).

## Progress Notes
Filed 2026-07-31 (Wave 5 kickoff).
