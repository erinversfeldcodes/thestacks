# Issue #004: Configure Fly.io deployment, Dockerfiles, and CI pipeline

## Summary
Wire up the full deployment stack: Fly.io app configs, multi-stage Dockerfiles for all three services, and a comprehensive monorepo-aware CI pipeline covering correctness, security, licence compliance, and deployability. Follows the script-first pattern: every check runs via a script callable both locally (`scripts/ci.sh`) and from GitHub Actions (`.github/workflows/ci.yml.disabled`). This is Phase 1E of the consolidated roadmap.

## User Stories
N/A — infrastructure.

## Goal
A green CI pipeline with strong confidence in deployability and security, and a first successful Fly.io deployment of all three services (core, vision, scraper) to the IAD region. Every push to a feature branch runs the full local suite; after passing, the stack is deployed to an ephemeral preview environment, Playwright E2E tests are run against it, and the environment is destroyed. Results are posted to the open PR.

## Technical Requirements

See roadmap: `plans/consolidated-roadmap.md` § Phase 1E.

---

### 1E.1 — Fly.io Configuration (already complete)
- `deploy/fly.core.toml` — Phoenix app, IAD region, health check at `/api/health` ✅
- `deploy/fly.vision.toml` — Python sidecar, private networking only ✅
- `deploy/fly.scraper.toml` — Rust scraper, private networking only ✅
- `deploy/Dockerfile.core` — multi-stage Elixir release ✅
- `deploy/Dockerfile.vision` — Python 3.12 slim ✅
- `deploy/Dockerfile.scraper` — Rust multi-stage ✅

---

### 1E.2 — CI Pipeline Scripts

All checks live in `scripts/` and are invoked by both `scripts/ci.sh` (local) and `.github/workflows/ci.yml.disabled` (GitHub Actions). The CI groups map 1-to-1 between the two.

#### Existing scripts (already implemented)
| Script | What it does |
|--------|-------------|
| `scripts/lint-elixir.sh` | `mix format`, `mix credo --strict`, `mix dialyzer`, `mix sobelow`, `mix deps.audit` |
| `scripts/test-elixir.sh` | Ecto reset, `mix test` |
| `scripts/lint-elm.sh` | `elm-format --validate`, `npm audit` |
| `scripts/test-elm.sh` | `elm-test` |
| `scripts/lint-rust.sh` | `cargo fmt --check`, `cargo clippy --deny warnings`, `cargo audit` |
| `scripts/test-rust.sh` | `cargo test` |
| `scripts/lint-python.sh` | `ruff check`, `ruff format --check`, `pip-audit` |
| `scripts/test-python.sh` | `pytest` |
| `scripts/lint-proto.sh` | `buf lint` |
| `scripts/lint-sql.sh` | `sqlfluff lint` |
| `scripts/test-dbt.sh` | `dbt run` + `dbt test` on staging layer |
| `scripts/security.sh` | `gitleaks`, `semgrep`, `hadolint`, `checkov`, `trivy fs` |

#### New / updated scripts (to implement in this issue)

**`scripts/test-e2e.sh`** (new)
- Starts Phoenix (:4000), frontend serve (:4001), vision sidecar (:8000) if not already running
- Waits for each port to be ready
- Runs `npm test` inside `e2e/` (Playwright, Chromium only)
- Stops services on exit via trap
- `E2E_SERVICES=none` skips starting services (for use against a live stack)
- `BASE_URL` override for deployed preview testing

**`scripts/security-squawk.sh`** (new)
- Git-diff-aware: only lints migration files added/modified since `origin/main` (or a specified base)
- Extracts raw SQL from `execute("...")` blocks and pipes to `squawk`
- `E2E_SQUAWK_ALL=1` to lint all migrations
- Skips gracefully if no changed migrations found

**`scripts/check-licenses.sh`** (new)
- Elixir: `mix licenses` via `licensir` — blocks GPL/AGPL packages
- Node (e2e/frontend): `npx license-checker --failOn GPL`
- Skips gracefully if `licensir` not installed (add-now: requires `mix.exs` dep)

**`scripts/deploy-preview.sh`** (new)
- Requires `FLY_API_TOKEN` and `NEON_PROJECT_ID`; skips gracefully if absent
- Creates ephemeral Fly app names: `stacks-core-pr-{branch}`, etc.
- Creates a Neon DB branch for the preview environment (instant fork, no cluster overhead)
- Deploys all three services with `fly deploy`
- Runs Playwright E2E against the deployed URL (`BASE_URL=https://...fly.dev`)
- Always destroys apps and Neon branch on exit (trap)
- Outputs a structured summary (PASS/FAIL per service + test results) for PR posting

**Updated `scripts/lint-elixir.sh`**
- Add `mix coveralls --minimum-coverage 80` (excoveralls already in `mix.exs`)

**Updated `scripts/lint-elm.sh`**
- Add `npx elm-review --config elm-review/ src/` with `NoUnused.Variables`, `NoUnused.Imports` rules

**Updated `scripts/test-python.sh`**
- Replace bare `pytest` with `pytest --cov=app --cov-fail-under=80`

**Updated `scripts/lint-proto.sh`**
- Add `buf breaking proto/ --against '.git#branch=main'` (backward-compat check)
- Skip gracefully if no `.proto` files exist

**Updated `scripts/security.sh`**
- Add `trufflehog filesystem .` (deeper entropy scanning alongside gitleaks)
- Add `syft . -o cyclonedx-json > sbom.json` + `grype sbom:./sbom.json --fail-on high`
- Add `dockle` CIS benchmark for each Dockerfile (build-time check, `--exit-code 1`)
- Add `dbt-checkpoint` model quality gates (source freshness, staging doc coverage)

---

### 1E.3 — `scripts/ci.sh` Groups

Updated group list (run sequentially, all accumulated before summary):

```
elixir  elm  rust  python  proto  dbt  security  e2e  licenses
```

Deploy phase runs **only** after all groups pass with zero failures:
- Calls `scripts/deploy-preview.sh`
- If `FLY_API_TOKEN` absent, logs a skip notice and exits 0 (local dev without credentials)

---

### 1E.4 — GitHub Actions (`.github/workflows/ci.yml.disabled`)

#### Path-scoped jobs (existing + updates)

| Job | Trigger paths | New additions |
|-----|--------------|---------------|
| `test-elixir` | `apps/core/**`, `mix.*` | excoveralls 80% gate, squawk on changed migrations |
| `test-elm` | `frontend/**` | elm-review NoUnused |
| `test-rust` | `apps/scraper/**` | (no change) |
| `test-python` | `apps/vision/**` | pytest-cov 80% gate |
| `lint-proto` | `proto/**` | `buf breaking` backward-compat |
| `test-dbt` | `dbt/**`, `apps/core/**` | (no change) |
| `test-e2e` | `frontend/**`, `apps/core/**`, `apps/vision/**`, `e2e/**` | New job — starts services, runs Playwright |
| `check-licenses` | `mix.lock`, `frontend/package-lock.json`, `e2e/package-lock.json` | New job |
| `security` | always | TruffleHog, Syft+Grype, Dockle (adds to existing gitleaks/semgrep/hadolint/checkov/trivy) |
| `security-squawk` | `apps/core/priv/repo/migrations/**` | New job, diff-aware |

#### New always-run jobs
- `gitleaks` — existing, unchanged
- `trufflehog` — new, always runs
- `hadolint` — existing, unchanged
- `semgrep` — existing, unchanged
- `checkov` — existing, unchanged
- `trivy` — existing, unchanged
- `syft-grype` — new, SBOM + CVE gate (CRITICAL/HIGH)
- `dockle` — new, CIS Docker benchmark

#### Deploy-preview job (new, runs after all jobs pass on push to non-main branch)
```yaml
deploy-preview:
  needs: [test-elixir, test-elm, test-rust, test-python, lint-proto, test-dbt, test-e2e, check-licenses, security]
  if: github.event_name == 'pull_request'
  steps:
    - Create Neon branch for this PR
    - Deploy stacks-core-pr-{pr_num}, stacks-vision-pr-{pr_num} to Fly.io (IAD)
    - Run Playwright E2E against https://stacks-core-pr-{pr_num}.fly.dev
    - Post deployed E2E results to PR (second sentinel block in PR body)
    - Destroy Fly apps + Neon branch (always, even on failure)
```

Sentinel blocks in PR body:
- `<!-- ci-summary-start -->` … `<!-- ci-summary-end -->` — local CI results (existing)
- `<!-- deployed-e2e-summary-start -->` … `<!-- deployed-e2e-summary-end -->` — deployed E2E results (new)

#### OSSF Scorecard (`.github/workflows/scorecard.yml.disabled`)
- Runs on a **weekly schedule** (not per PR — too slow and requires elevated token)
- Uses `ossf/scorecard-action@v2`
- Uploads results to GitHub Security tab as SARIF
- Evaluates: Branch-Protection, CI-Tests, Pinned-Dependencies, SAST, Token-Permissions, Vulnerabilities, Signed-Releases
- Expected initial score: ~3.5–5.0 (CI disabled, no signed releases yet)

---

### 1E.5 — Git Hook Updates (`scripts/hooks/lib/update-pr-ci.sh`)

The pre-push hook currently:
1. Runs `just ci` (local checks)
2. Formats results as a markdown table in `<!-- ci-summary-start/end -->`
3. Posts to open PR

New behaviour:
1. Run `just ci` — local checks (unchanged)
2. If all local checks pass AND `FLY_API_TOKEN` set: run `scripts/deploy-preview.sh`
3. Format deployed E2E results as a separate table in `<!-- deployed-e2e-summary-start/end -->`
4. Update PR body with both sections (local CI section first, deployed E2E section below)

---

### 1E.6 — DAST / Security-Against-Attack Tools

Run against the deployed preview environment (after deploy-preview succeeds):

| Tool | What it tests | Where |
|------|--------------|-------|
| OWASP ZAP baseline | Passive DAST — headers, CSP, cookie flags, open redirects | `deploy-preview.sh` step |
| Nuclei (jwt + misconfig templates) | JWT algorithm confusion, HTTP misconfigs, info leakage | `deploy-preview.sh` step |
| jwt_tool | `alg:none`, HMAC brute-force, token reuse after logout | `deploy-preview.sh` step |
| Custom IDOR script | Two authenticated sessions, cross-user resource access | `deploy-preview.sh` step |

All DAST tools only run against the ephemeral preview — never production. ZAP runs in passive/baseline mode only (no active spider that modifies data).

---

### 1E.7 — Pre-flight Credentials

| Secret | Where used |
|--------|-----------|
| `FLY_API_TOKEN` | Deploy + destroy ephemeral apps |
| `NEON_PROJECT_ID` | Create/delete per-PR Neon branches |
| `NEON_API_KEY` | Neon branch management API |
| `MODAL_TOKEN_ID` | Modal deploy + URL lookup for vision sidecar |
| `MODAL_TOKEN_SECRET` | Modal deploy + URL lookup for vision sidecar |
| `VISION_HMAC_SECRET` | Elixir → vision HMAC auth in preview |
| `SECRET_KEY_BASE` | Phoenix in preview env |
| `GITHUB_TOKEN` | ossf/scorecard, PR body updates |

---

## Definition of Done

**Infrastructure (1E.1)**
- [x] `deploy/Dockerfile.*` builds all three services
- [x] `deploy/fly.*.toml` configs present for IAD region
- [ ] First `fly deploy` to IAD succeeds for all three apps (needs credentials)
- [ ] Phoenix health check (`/api/health`) returns 200 on Fly
- [ ] Vision sidecar unreachable from public internet (private networking only)
- [ ] `.env.example` matches all vars in `config/runtime.exs`

**CI Scripts (1E.2)**
- [ ] `scripts/test-e2e.sh` starts services, runs Playwright, cleans up
- [ ] `scripts/security-squawk.sh` lints only changed migrations
- [ ] `scripts/check-licenses.sh` blocks GPL/AGPL deps
- [ ] `scripts/deploy-preview.sh` deploys + tests + destroys ephemeral stack
- [ ] `scripts/lint-elixir.sh` enforces 80% coverage gate
- [ ] `scripts/lint-elm.sh` runs elm-review NoUnused rules
- [ ] `scripts/test-python.sh` enforces 80% coverage gate
- [ ] `scripts/lint-proto.sh` runs buf breaking check
- [ ] `scripts/security.sh` includes TruffleHog, Syft+Grype, Dockle

**CI Pipeline (1E.4)**
- [ ] `ci.yml.disabled` has `test-e2e`, `check-licenses`, `security-squawk`, `syft-grype`, `dockle`, `deploy-preview` jobs
- [ ] `scorecard.yml.disabled` has weekly ossf/scorecard schedule
- [ ] All path-scoped jobs trigger only on relevant file changes
- [ ] `deploy-preview` job only runs on PRs after all other jobs pass

**Hook (1E.5)**
- [ ] Pre-push hook posts deployed E2E results in a second sentinel block below local CI results
- [ ] Hook skips deploy section gracefully if `FLY_API_TOKEN` absent

**Local dev**
- [ ] `just ci` runs all groups including e2e (with services started)
- [ ] `just ci security` runs security checks standalone
- [ ] `nix develop` drops into shell with all language toolchains available

## Dependencies
- Issues #001, #002, #003 committed to `main`
- Human: Fly.io org, apps, and Postgres cluster provisioned
- Human: Neon project created (`NEON_PROJECT_ID` available)
- Human: Cloudflare R2 bucket and API tokens provisioned
- Human: Domain and DNS configured
- Human: GitHub secrets populated (FLY_API_TOKEN, NEON_*, MODAL_TOKEN_ID, MODAL_TOKEN_SECRET, etc.)

## Agent Assignment
- **platform-agent** (`docs/agents/platform-agent.md`)
- **Reviewer**: platform-reviewer (`docs/agents/reviewers/platform-reviewer.md`)
- **Model**: Sonnet 4.6

## Progress Notes
<!-- Updated by agents during execution -->
- 2026-03-10: Full scope defined based on research into security tooling, DAST, Fly.io ephemeral apps, Neon branches, ossf/scorecard, hex_licenses (licensir), and squawk git-diff-aware invocation. Implementation not yet started.
