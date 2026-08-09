# Issue #381: Five more places the test suite can dial the public internet

> **Campaign assignment:** Wave 11 (launch gates) — `plans/staff-campaign-2026-07-30.md`. Tracked in the campaign state; completed as part of epic #321.


## Summary
The sibling sweep #377 was asked for, reported. **13 modules make direct `Finch` calls; 8 are properly
behind a seam; 5 are not.** Of those five, **3 are test-reachable** and **2 can dial a real, resolvable
third-party host**.

⚠️ **This is now a confirmed class, not an anecdote.** Two separate Wave 7 failures — **#377**
(`DiscoverAuthorSourcesJob` dialling `authorsite.com`) and **#379** (a third-space test geocoding
against the live `nominatim.openstreetmap.org` and returning coordinates for a real building in
Berkshire) — were both un-seamed outbound calls that presented as flaky tests. Neither was diagnosed
until someone chased it instead of re-running.

## The five

**1. `Stacks.Books:754` — HIGH, and worse than #377.**
`download_cover/1` issues a live GET to **`https://example.com/cover.jpg`** on every
`confirm_cover_association/2`, exercised by `books_test.exs:564,578,599` and
`internal_controller_test.exs:74-93`.
⚠️ **Those assertions silently depend on the remote returning non-200.** If `example.com/cover.jpg`
ever started returning 200, `assert updated.cover_image_url == "https://example.com/cover.jpg"` would
**fail** — correctness that depends on a third party's HTTP status. That is a strictly worse failure
mode than a hang.

**2. `Stacks.CircuitBreakers` — HIGH, latent.**
Probes dial **`openlibrary.org`** and **`googleapis.com`** 15 s after any fuse blown via `melt/1`.
Masked today only by `on_exit` fuse resets winning a timing race — the same "safe by coincidence"
shape as #379, which lost that race.

**3. `Stacks.Geocoding.Nominatim` — MEDIUM. ⚠️ Partially addressed by #379; verify before closing.**
It has 3 of the 5 seam elements. #379 added `config :core, :geocoder, Stacks.Geocoding.Mock` to
`config/test.exs`, which closes the test-reachability. Confirm nothing else re-opens it.

**4. `RSSLivenessJob:68` — MEDIUM.**
Identical shape to the bug #377 fixed, in the same file family. Survivable today only because its
tests use `.invalid` hosts — i.e. safe by fixture choice, not by construction. #377 left a `⚠️`
comment rather than fixing it under scope lock.

**5. `MetricsPusher` — LOW.** Unreachable by construction. Listed for completeness.

## The cross-cutting finding
⚠️ **Only `RssFetcher` sets `request_timeout`.** Every other Finch call site relies on
`receive_timeout` alone — and #377 proved by measurement that `receive_timeout` is **per-chunk**,
while `request_timeout` (which bounds the whole response) defaults to **`:infinity`**. A peer
dribbling 17 bytes took **35 s** against a "5 s" `receive_timeout`.

So every un-seamed site above is also an unbounded-response site. ⚠️ Do not assume the connect is the
problem: #377's stack trace pointed at `ssl.connect` and everyone concluded the connect was unbounded.
It was already bounded at 5 s by Finch's own default. The trace showed where the process was *waiting*,
not where the bound was missing.

## User Stories
None — test-suite integrity and production resilience.

## Scope Check
⚠️ Five sites of differing severity. **Likely a parent.** Sites 1 and 2 are independently urgent and
could each be their own child; 3 is verification only; 4 is a one-liner; 5 is a no-op. Split rather
than forcing one diff.

## Technical Requirements
1. **Site 1 first** — it is the only one where a third party's response can make a test assert the
   wrong thing rather than merely hang.
2. **Seam each reachable site**, following `:rss_fetcher` (behaviour + config key + mock). ⚠️ Reuse
   existing seams where one exists; #377 added `probe/1` to `RssFetcherBehaviour` rather than
   introducing a second config key, and that is the pattern.
3. **Set `request_timeout` at every remaining call site**, or state per site why the default is right.
4. **Prove no real host is reached** by attaching to Finch's own `[:finch, :request, :start]`
   telemetry and asserting the dialled list is empty — the technique #377 used. ⚠️ A
   "the mock was called" assertion does not prove the real transport was not *also* called.
5. **Add a gate.** ⚠️ Both #377 and #379 were found by accident, months apart. A check that every
   outbound-client config key has a `:test` default — the exact thing whose absence caused #379 —
   would have caught it at the edge. `scripts/check-session-expiry-coverage.sh` is the exemplar for a
   discovering gate rather than a roster.

## Reviewer Context
- ⚠️ **Do not delete or skip the affected tests.** They cover real behaviour; the defect is the
  un-seamed transport.
- #379's sweep found `:geocoder` was the **only** config key meeting its reachability criterion (no
  test default + ≥2 concurrent async mutators) — now zero. `:public_shelf_cap` meets the looser
  structural criterion but is not reachable today (only one of its two mutators is async). That is a
  different axis from this issue's Finch-call axis; both matter.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elixir | yes | ❌ site 1: no live GET; the assertion no longer depends on a remote's status code |
| Elixir | yes | ❌ site 2: fuse probes seamed; no dial to openlibrary/googleapis in test |
| Elixir | yes | ❌ every call site bounded by `request_timeout`, or its absence justified per site |
| CI/gate | yes | ❌ a gate fails when an outbound client key has no `:test` default |
| Regression | yes | ❌ Finch telemetry asserts an empty dialled list across the suite |

## Definition of Done
- [x] Site 1 seamed; assertion no longer remote-dependent — evidence: f762ea07 (381a), `HttpClientBehaviour.get_binary/1` + transport-isolation test, mutation-probed RED
- [x] Site 2 seamed — evidence: 2026-08-09 diff — all 4 bare Finch sites in `circuit_breakers.ex` route through the `:circuit_breaker_probe_http_client` seam (`ProbeHttpClientBehaviour`; `:test` floor = `Stacks.Testing.DisabledProbeHttpClient`); "probe transport isolation (#381b)" test attaches to `[:finch, :request, :start]`, mutation-probe RED (seam bypass → 1 failure), restored green 48/0
- [x] Site 3 verified closed by #379 — evidence: `config :core, :geocoder, Stacks.Geocoding.Mock` present in `config/test.exs`, and `check-outbound-test-default.sh --list` reports `Stacks.Geocoding.Nominatim [ok]` — the gate now re-verifies this every run
- [x] Site 4 seamed — evidence: 2026-08-09 diff — `RSSLivenessJob.check_feed/1` probes via the `:rss_fetcher` seam (`RssFetcher.probe/1`, which bounds both phases); success-path test added, mutation-probe RED (seam bypass → "records success" fails), restored green 7/0
- [x] `request_timeout` set or justified at every site — evidence: audit list in Progress Notes below; sweep `grep Finch.request | grep -v request_timeout` returns only sites carrying it multiline or via `request_opts`
- [x] Gate added, with a counterfactual red — evidence: `scripts/check-outbound-test-default.sh` (discovering: any module calling `Finch.request` must be seam-selected with a `:test` floor), wired into `lint-elixir.sh`; counterfactual A (floor removed) FAIL naming the key, counterfactual B (floor = real client) FAIL "the floor points at the internet", restored OK 10 transports/1 exempt
- [x] `staff-review` verdict recorded below — see Wave 11 close-out

## Dependencies
Reported by **#377**'s sweep; corroborated by **#379**, which was the same class found independently.
No blocker. ⚠️ Worth doing before the campaign's remaining gates — two of the last three unexplained
suite failures were this class.

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-08-03 by the lead from #377's sweep (13 modules examined, 5 un-seamed) with #379's
independent corroboration. Site 1's remote-dependent-assertion hazard and site 2's timing-race masking
are the sweeping agent's findings, not the lead's.

## Progress (2026-08-09, Wave 11)
- **381a DONE** (f762ea07): `Books.download_cover/1` seamed through `HttpClientBehaviour.get_binary/1` (new callback; real client + MockHttpClient + FailingHttpClient all implement it). Test no longer dials out — transport-isolation test added + mutation-probed (bare-Finch revert reds it). Also bounds the request (`request_timeout` + `receive_timeout`) — closes #381d for this site.
- **381b DONE** (2026-08-09): the 4 bare Finch sites in `circuit_breakers.ex` (together_ai, brave, r2, `probe_http_get`) now go through one seamed transport — `ProbeHttpClientBehaviour.get(url, headers) -> {:ok, status}` so per-probe status policy (200-only vs R2's sub-500) stays in the breaker. `:test` floor: `Stacks.Testing.DisabledProbeHttpClient` returns `{:error, :outbound_disabled_in_test}` — a mid-suite probe now reads as a failed probe and the fuse recovers on the backstop, instead of dialling openlibrary.org.
- **381c DONE** (2026-08-09): `RSSLivenessJob` probes via the `:rss_fetcher` seam. Fidelity note: non-2xx statuses are now recorded as `:not_found` rather than `"HTTP 404"` — `probe/1` deliberately collapses status detail; acceptable for a liveness boolean and stated in the moduledoc.
- **381d DONE** (2026-08-09): whole-response bound audit. Sites now carrying `request_timeout` (value, justification): searxng 20s / brave 20s / nominatim 15s (small JSON, margin over receive); vision client = `@receive_timeout_ms` and scraper 600s/120s/30s ×5 (server holds the connection while working then returns small JSON — chunk budget == whole budget); together 30s ×2; transparency-prometheus 8s; metrics-pusher 10s; books get 15s (was fully unbounded: Finch defaults request_timeout to `:infinity`); books get_binary 10s + probe client 5s (already). `RssFetcher` already bounded via `request_opts/1`.
- **381e DONE** (2026-08-09): `scripts/check-outbound-test-default.sh`, modelled on `check-session-expiry-coverage.sh` — the roster is recomputed each run (any module under `apps/core/lib` calling `Finch.request` must be selected through an `Application.get_env(:core, :key, Module)` seam whose key has a `:test` default that is not the real client). 11 transports discovered, 10 ok, 1 exempt (`Core.PromEx.MetricsPusher`: `init/1` → `:ignore` without `:metrics_push_url`, never set in test). Stale exemptions fail. Wired into `scripts/lint-elixir.sh`.
- Full core suite after all four: **3553 tests, 0 failures**; credo --strict clean.


## Wave 11 close-out (2026-08-09)
staff-review (Mode B shadow, 2026-08-09): **LGTM** — one probe transport with per-probe status policy kept in the breaker (deep module, thin seam); the discovering gate closes the whole class at the edge — counterfactual A/B both red. Self-review by the implementing session, backed by 8 mutation probes all RED-then-restored and 3553/0.
