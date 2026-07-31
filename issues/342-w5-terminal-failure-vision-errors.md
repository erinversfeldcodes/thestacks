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
Built across two agents (first stalled on a watchdog; its 637 lines were preserved as `0d8d3bc5` and finished by a second). Commit 28d96aa3; merged into `feat/campaign-w5-315`. 10 files, +1153/−57.
**staff-review verdict: LGTM** (2026-07-31, Mode B on 28d96aa3). This is the strongest child of the campaign so far. Praise: (a) **the inherited WIP's `timeout/1` defeated its own guarantee, and the finishing agent found it by reading Oban's source.** `c:Oban.Worker.timeout/1` is implemented as `:timer.exit_after/2` (`deps/oban/lib/oban/queue/executor.ex:132`) — an *asynchronous exit signal* that `try/catch` cannot intercept — so a timed-out final attempt would skip the wrapper entirely and leave the row `pending`. **The mechanism added to bound the job reintroduced the exact bug the issue exists to fix.** Replaced with in-process `run_bounded/1` (`Task.async` + `Task.yield`, the task catching everything as data because `Task.async` links and a genuine crash would kill the caller uncatchably); (b) it caught that the WIP's `@attempt_timeout_ms 240_000` was **shorter than the work it bounds** — an attempt makes *two* sequential 210s waits, so 240s would routinely kill jobs that were about to succeed — and fixed it to `2 × receive_timeout_ms() + 30s`, extracting `AIClient.receive_timeout_ms/0` so three copies of `210_000` became one source; (c) it found the WIP had converted only **3 of 10** sidecar raise sites, and its own Python contract test is what caught that; (d) **a PII fix nobody asked for**: Pydantic validates *before* the handler body, so the mutual-exclusion check was dead code and every schema failure returned unlabelled and was retried 3× — the new `RequestValidationError` handler deliberately drops Pydantic's `input` key, which echoes base64 image bytes and `/associate`'s user-linked ids; (e) the zero-row sweep is **real committed SQL** (`rejected 16 / pending 0`) rather than a rolled-back assertion, it cleaned up after itself, and it was honest that its own committed `event_log` rows briefly reddened another test — its pollution, reported rather than hidden; (f) it caught **a vacuous test of its own** (a storage-presign test passing because `Storage.Mock.presigned_url` always succeeds) and added a `$callers`-walking `put_presign_error/1` seam; (g) attempt-count assertions include `det_calls < trans_calls`, which catches a "fix" that cancels everything or retries everything — both of which pass an outcome-only test.
**Lead independent verification (two targets the child did not probe):**
1. **Confirmed the Oban claim in the dependency's own source** rather than taking it on trust: `deps/oban/lib/oban/queue/executor.ex` does `:timer.exit_after(timeout, TimeoutError.exception(...))`. `def timeout(` is now absent from the worker (grep → 0).
2. **Probed the ceiling correction** — restored the WIP's wrong `240_000`. Red on exactly the guarding assertion: `assert IdentifyBookJob.attempt_timeout_ms() > 2 * AIClient.receive_timeout_ms()` (17 tests, 1 failure). The correction is tested, not merely reasoned. Reverted via Edit; `git status` clean, `grep -c` → 1.
**⚠️ Number worth the owner's attention:** the SSE deadline is now *derived* from job death rather than hardcoded — `3 × 450s + 36s = 1,386,000 ms (23.1 min)`, against the old hardcoded 360s. That is **3.9× longer**, but it is a **ceiling, not a wait**: the terminal guarantee broadcasts the moment the job dies, so the reader sees failure in seconds. The old 360s was the bug — it expired while the job was still legitimately running.
**Finding 4 CORRECTED by the lead — sobelow DOES run.** The child reported `just run mix sobelow --config` failing from the repo root ("does not appear to be a Phoenix application") and concluded sobelow had not run. It does: `scripts/lint-elixir.sh:7` invokes it as `(cd apps/core && mix sobelow --config)`, and running the canonical script gives **"No vulnerabilities found."** This is the project's "use canonical scripts, not a hand-rolled equivalent" rule — recorded so nobody chases a gate gap that does not exist.
**GDPR lens: PASS** — no migrations, no new columns, no new user FK; new `rejection_reason` values are fixed tokens not free text; `image.rejected` payload shape unchanged; telemetry metadata asserted to be exactly `[:code, :determination]`, both atoms, no service-supplied text. Net improvement via the Pydantic `input`-key drop. `image.*` correctly stays in `@unsubscribed` with no handler added.
Probes (child's, all reverted, `grep -c` verified): remove wrapper → **12/17 red** (`15 uploaded_images row(s) left pending after sweeping 15 failure branches`); remove determination split → **4/17 red** (`a deterministic vision failure was retried on the GPU 3 times`); remove a `MALFORMED_REQUEST` clause → enum-coverage gate FAILs *and* 2 Elixir contract tests red; unlabel one sidecar raise → 2 Python tests red.
Suites: core **3330/0** (15 properties, 9 excluded), vision **134 passed**, dialyzer **0 errors**, credo clean, ruff clean, all five proto targets OK.
**Findings carried forward:** (1) `cleanup_stuck_images/0` (`gdpr/image_retention.ex`) sweeps `pending` rows older than N hours and was **the only thing rescuing these uploads** — its count should now fall to ~0, which makes it a useful production signal that the guarantee holds; (2) base64 validation is duplicated 3× in `apps/vision/app/main.py`; (3) `upload_pipeline_test.exs:545` uses an absolute `event_count == 1`, sandbox-safe today but fragile to anything that commits.
