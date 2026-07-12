---
name: write-validation-test
description: Write a test that actually validates a behaviour — at the right layer, and against a live stack via realistic user behaviour when browser E2E is the wrong tool. Use when a behaviour needs a validation path, when a test audit cell is ❌, when Playwright is inappropriate but the behaviour still must be proven end-to-end, or when asked to "write a test / acceptance test / live-stack test for X".
---

# write-validation-test

Every behaviour in the system must be validatable and verifiable. "Playwright is the wrong tool
here" is never a reason to skip validation — it is a reason to pick a *different* real test. This
skill picks the right layer and, for live-stack tests, keeps them honest: they must reach the state
the way a real user would.

## 1. Pick the right layer (cheapest that actually proves the behaviour)

| Behaviour | Right layer | Where |
|-----------|-------------|-------|
| Pure logic, parsing, a plug's decision | unit | `apps/core/test/**`, `frontend/tests/**`, `apps/scraper` cargo, `apps/vision/tests` |
| A service boundary / context function / controller action | integration | `apps/core/test/stacks_web/**`, context tests |
| A whole user-story journey (the user's goal, start to finish) | **acceptance** | `apps/core/test/acceptance/us_X_Y_Z_*.exs` — one per US |
| The same journey against **real infrastructure** (real DB, Modal, R2, external APIs) | **live-stack** | acceptance/E2E run under `TEST_TARGET=deployed BASE_URL=…` via `scripts/test-deployed.sh` |
| A browser/UI flow (rendering, clicks, redirects) | Playwright E2E | `e2e/tests/*.spec.ts` (reads `BASE_URL`) |
| A data-shape / referential-integrity guarantee | dbt test | `dbt/**/schema.yml`, `dbt/tests/**` |

Prefer the cheapest layer that would **fail if the behaviour broke**. Add a higher layer only when
it proves something the lower one can't (real integration, real user journey, real browser).

## 2. Live-stack tests must reflect realistic user behaviour

A test that runs against a live stack (`TEST_TARGET=deployed` / preview `BASE_URL`) earns its cost
only if it reaches the state the way a real user does. Rules:

- **Drive the public surface, not the internals.** Hit the real API/UI a user would (`POST
  /api/auth/login`, upload a photo, click through onboarding) — do not reach into the DB, call
  private functions, or flip app-env to force the state under test.
- **Reach the precondition naturally.** If you're testing "session expired → redirect to login",
  get there the way a user does (a token that actually expired / was revoked via logout), not by
  hand-editing a token or poking ETS. If setup is genuinely impossible through the public surface,
  that's a signal the behaviour may be untestable-as-specified — say so, don't fake it.
- **Assert what the user observes** (status codes, response bodies, redirects, rendered state, the
  audit/event row that results), plus the durable side effect where it matters.
- **No mocks on a deployed run.** `TEST_TARGET=deployed` means real Modal/Open Library/R2/Neon —
  the point is to catch the integration failures mocks hide. Tolerate real-world latency (cold
  starts) with the deployed timeouts already wired (`e2e/playwright.config.ts` bumps to 90 s;
  acceptance runs get the deployed envelope).

## 3. Make it non-vacuous
- The test must fail if the feature is removed or inverted. Prove it: for a new test, show it RED
  before the implementation (test-first); for coverage backfill, mutate the impl and confirm it
  flips RED.
- Assert behaviour, not existence. No `assert true`, no "it compiled", no asserting only that a
  request returned *something*.
- Security/`sad`-path cells are the highest value — a forged header, an expired token, a wrong
  password, a rotated IP. Cover the abuse path, not just the happy path.

## 4. Wire-up reference
- Local (mocked, default): `MIX_ENV=test`, `TEST_TARGET=local` — `just test` / `mix test`.
- Live stack: `TEST_TARGET=deployed BASE_URL=https://<preview>.fly.dev just test-deployed`
  (`scripts/test-deployed.sh` — needs `.env`: `set -a; source .env; set +a`).
- Browser against a preview: `E2E_SERVICES=none BASE_URL=https://<preview>.fly.dev just test-e2e-ci`.
- See `docs/agents/standards/testing.md` (the 12-layer strategy + `TEST_TARGET` matrix) and the
  `testing-coordinator` agent for cross-cutting coverage.

## 5. Deployed Elixir tests (`@tag :deployed_only`) — hard-won gotchas
Tag with `@moduletag :deployed_only` (excluded by `test_helper.exs`; run via `scripts/test-deployed.sh`
/ `mix test --only deployed_only`), guard on `System.get_env("BASE_URL")` (skip when unset so a bare
`--only deployed_only` run stays inert, not red). Then:
- **Do NOT read the preview DB through `Core.Repo`.** `config/test.exs` hardcodes `Core.Repo` to
  `localhost/stacks_test`, and there is no deployed override — so `DATABASE_URL=<preview>` does NOT
  repoint it. A `Repo.query` will silently hit localhost (empty → "not found"). Open a **direct
  `Postgrex.start_link`** from `System.get_env("DATABASE_URL")` in `setup` (parse the URL; Neon needs
  `ssl: true`, `ssl_opts: [verify: :verify_none]`) and query through that connection.
- **A row the live app committed over HTTP is on a different connection** — read it on a normal
  (non-sandbox-transaction) connection so it's visible; the direct Postgrex conn above is that.
- **Absorb cold-start 502s at the request level.** The preview may have auto-stopped; the first
  `Req.post!` can 502. A real user retries — so add `retry: :transient, max_retries: 8, retry_delay:
  <2s→10s backoff>`. (Same class as the Issue #175 warmup guard, one layer down.)
- **UUID params:** comparing a text UUID against a `uuid` column via `$1::uuid` makes Postgrex try to
  encode a 16-byte binary and fail. Compare the column cast to text instead: `WHERE id::text = $1`.
- **Bucket/idempotency awareness:** rate-limit or lockout state on a shared preview is real and
  window-based — order tests so a saturating test runs last/alone, and prefer unique emails/ids per
  run to avoid cross-run collisions on a shared branch.

## Output
The test file(s) at the right layer, plus a one-line note of *why this layer* and the RED-before /
mutation evidence that it's non-vacuous. If a behaviour genuinely can't be validated at any layer,
say so explicitly (it becomes an `n/a`-with-rationale in the audit, or a redesign flag) — never a
silent gap.
