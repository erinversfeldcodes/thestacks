# The Stacks — Task Runner
set dotenv-load

# Start all available services for local development.
# Compiles Elm, runs migrations, then starts Phoenix (always),
# the vision sidecar (if apps/vision/app/main.py exists), and
# the scraper (if apps/scraper/src/main.rs exists).
# Opens http://localhost:3000 in your browser when ready.
# Press Ctrl-C to stop all processes.
dev:
    #!/usr/bin/env bash
    set -euo pipefail
    just db-create 2>/dev/null || true
    just db-migrate

    echo "==> Generating Ecto schemas from proto..."
    cd apps/core && mix proto.sync && cd ../..

    echo "==> Generating Elm proto decoders..."
    bash scripts/gen-elm-proto.sh

    echo "==> Building assets (Elm + CSS via esbuild)..."
    (cd apps/core/assets && npm run deploy)

    # Kill any stale processes from a previous dev session on our ports.
    echo "==> Cleaning up stale dev processes..."
    lsof -ti :4000 | xargs kill -9 2>/dev/null || true
    lsof -ti :8000 | xargs kill -9 2>/dev/null || true
    pkill -f "stacks-scraper" 2>/dev/null || true
    sleep 0.5

    trap 'kill $(jobs -p) 2>/dev/null; exit 0' EXIT INT TERM

    echo "==> Starting Phoenix on http://localhost:4000"
    mix phx.server &

    if [ -f apps/vision/app/main.py ]; then
        if [ ! -f apps/vision/.venv/bin/uvicorn ]; then
            echo "==> Installing vision sidecar dependencies..."
            python3 -m venv apps/vision/.venv
            apps/vision/.venv/bin/pip install -q -r apps/vision/requirements.txt
        fi
        echo "==> Starting vision sidecar on http://localhost:8000"
        (cd apps/vision && .venv/bin/uvicorn app.main:app --reload --port 8000) &
    else
        echo "==> Vision sidecar not built yet — skipping (Phase 1D)"
    fi

    if [ -f apps/scraper/src/main.rs ]; then
        echo "==> Starting scraper"
        (cd apps/scraper && cargo run) &
    else
        echo "==> Scraper not built yet — skipping (Phase 2)"
    fi

    echo ""
    echo "    The Stacks is running at http://localhost:4000"
    echo "    Press Ctrl-C to stop."
    echo ""
    sleep 1 && open http://localhost:4000 &
    wait

# Bootstrap the full development environment (idempotent)
setup:
    bash setup.sh

# Install git hooks and ensure Claude Code hook scripts are executable.
# Claude Code hooks (.claude/settings.json) activate automatically — this
# just ensures execute bits are set after a fresh clone.
install-hooks:
    bash scripts/install-hooks.sh

# Install or update flyctl from GitHub releases (superfly/homebrew-tap is abandoned)
install-flyctl:
    bash scripts/install-flyctl.sh

# Check if flyctl update is available
check-flyctl:
    bash scripts/install-flyctl.sh --check

# Run every CI check locally in CI order (sequential, all groups)
# Optionally pass group names to run a subset: just ci elixir dbt
ci *GROUPS:
    scripts/ci.sh {{GROUPS}}

# Run a GitHub Actions job locally via act (requires Docker).
# Usage: just act test-elixir
act JOB:
    act -j {{JOB}}

# Install Python dev dependencies (pytest, ruff, mypy, pip-audit, etc.)
install-python-dev:
    cd apps/vision && .venv/bin/pip install -r requirements-dev.txt

# Run all tests
test: test-elixir test-elm test-rust test-python test-dbt

# Full pre-merge verification gate — run before requesting reviews.
# Covers lint, tests, proto drift, dbt models, dbt-checkpoint quality, and Elm lint+tests.
verify: lint-elixir test-elixir lint-elm test-elm lint-proto proto-sync-check test-dbt lint-dbt

# Elixir tests
test-elixir:
    scripts/test-elixir.sh

# Elm tests
test-elm:
    scripts/test-elm.sh

# Rust tests
test-rust:
    scripts/test-rust.sh

# Python tests
test-python:
    scripts/test-python.sh

# Run the vision sidecar Atheris fuzz target against the seed corpus (all platforms)
# Pass -- -atheris_runs=N to run the full fuzzer (Linux + atheris installed only)
# atheris lives in requirements-fuzz.txt rather than requirements-dev.txt
# (it doesn't compile on Python 3.12 — see the comment in -dev.txt). When
# ARGS includes `-atheris_runs=*`, ensure atheris is in the venv first.
fuzz-vision *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ " {{ARGS}} " == *"-atheris_runs="* ]]; then
        apps/vision/.venv/bin/pip install -q -r apps/vision/requirements-fuzz.txt
    fi
    cd apps/vision && PYTHONPATH=. VISION_ENVIRONMENT=test .venv/bin/python tests/fuzz_image_input.py {{ARGS}}

# Run all linters (check only — no modifications)
lint: lint-elixir lint-elm lint-rust lint-python lint-proto lint-sql lint-dbt

# Elixir lint
lint-elixir:
    scripts/lint-elixir.sh

# Elm lint
lint-elm:
    scripts/lint-elm.sh

# Rust lint
lint-rust:
    scripts/lint-rust.sh

# Python lint
lint-python:
    scripts/lint-python.sh

# Protobuf lint
lint-proto:
    scripts/lint-proto.sh

# SQL lint
lint-sql:
    scripts/lint-sql.sh

# dbt-checkpoint quality gates (requires dbt/target/manifest.json)
lint-dbt:
    scripts/lint-dbt.sh

# Generate Elm proto decoders from .proto files
gen-elm-proto:
    scripts/gen-elm-proto.sh

# Check Elm proto decoders are up to date (CI)
gen-elm-proto-check:
    scripts/gen-elm-proto.sh --check

# Auto-fix all fixable lint and formatting issues
format:
    scripts/format.sh

# Create database
db-create:
    mix ecto.create

# Run database migrations
db-migrate:
    mix ecto.migrate

# Verify all migrations are reversible
db-rollback-check:
    mix ecto.rollback --all --quiet && mix ecto.migrate --quiet

# Reset database (drop + create + migrate + seed)
# Seeds are run explicitly here because Mix alias chaining doesn't reliably
# start the full application context needed by Repo.insert_all.
db-reset:
    mix ecto.reset
    mix run apps/core/priv/repo/seeds.exs

# Run Playwright E2E tests (requires just dev to be running on :4000/:4001)
test-e2e:
    cd e2e && npm test

# Run dbt run + test (staging layer only)
# Resets the DB, loads Ecto seeds, then validates dbt staging models.
test-dbt:
    scripts/test-dbt.sh

# Security scans (SAST + secrets + deps + IaC)
test-security:
    scripts/security.sh

# Lint protobuf schemas (alias for lint-proto)
buf-lint:
    scripts/lint-proto.sh

# Generate code from protobuf schemas
buf-generate:
    buf generate proto/

# Generate Ecto schemas + dbt models from proto definitions
proto-sync:
    cd apps/core && mix proto.sync

# Check proto-to-schema drift (CI mode — no writes)
proto-sync-check:
    cd apps/core && mix proto.sync --check

# Run E2E tests with service lifecycle management
test-e2e-ci:
    scripts/test-e2e.sh

# Check licence compliance
check-licenses:
    scripts/check-licenses.sh

# Lint changed migrations with squawk
squawk:
    scripts/security-squawk.sh

# Run deployed-only tests against a preview stack (requires TEST_TARGET=deployed)
test-deployed:
    bash scripts/test-deployed.sh

# Deploy ephemeral preview + run E2E against it + destroy
deploy-preview:
    scripts/deploy-preview.sh

# ── Pinned-toolchain runner ───────────────────────────────────────────────────
# Run ANY command inside the pinned Nix dev shell (Elixir 1.18.4 / OTP 27).
#
# WHY THIS EXISTS: shells WITHOUT direnv active — git hooks, CI, and AI coding
# agents whose non-interactive Bash never triggers `.envrc` — fall back to a
# SYSTEM Elixir (e.g. Homebrew 1.18/1.19/OTP 28). Compiling `_build` with the
# system toolchain and then loading those beams under the flake toolchain (as the
# pre-push hook and CI do via `nix develop`) corrupts `_build` ("corrupt atom
# table" on core modules, stale/again-missing dialyzer PLTs). The fix is to run
# every Elixir/mix/iex command — and the `verify`/`ci` recipes — through the SAME
# pinned shell. Examples:
#   just run mix test
#   just run mix dialyzer
#   just run just verify
#   just run just ci
run *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    # Non-interactive shells often lack nix on PATH even when it is installed.
    export PATH="/nix/var/nix/profiles/default/bin:${HOME}/.nix-profile/bin:${PATH}"
    if [[ -n "${STACKS_DEV_SHELL:-}" ]]; then
        # Already inside the pinned dev shell — run directly, don't re-wrap.
        exec {{ARGS}}
    fi
    if ! command -v nix >/dev/null 2>&1; then
        echo "ERROR: nix not found (looked on PATH + /nix/var/nix/profiles/default/bin)." >&2
        echo "Install Nix, or run from a direnv-activated shell, before using 'just run'." >&2
        exit 1
    fi
    exec nix develop --command {{ARGS}}

# Diagnose the Elixir toolchain: does the bare shell match the pinned dev shell?
# If they differ, do NOT run bare `mix` — use `just run mix ...` (see `just run`).
doctor:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "bare-shell elixir:   $(elixir --version 2>/dev/null | tail -1 || echo 'not found')"
    export PATH="/nix/var/nix/profiles/default/bin:${HOME}/.nix-profile/bin:${PATH}"
    if command -v nix >/dev/null 2>&1; then
        pinned="$(nix develop --command elixir --version 2>/dev/null | tail -1)"
        echo "pinned (nix) elixir: ${pinned}"
        if [[ "$(elixir --version 2>/dev/null | tail -1)" != "${pinned}" ]]; then
            echo "MISMATCH: run Elixir tooling via 'just run …' (never bare mix) to avoid corrupting _build."
        else
            echo "OK: bare shell matches the pinned toolchain."
        fi
    else
        echo "nix: NOT found — bare 'mix' will use the system toolchain; prefer 'just run' once nix is available."
    fi

# Bundle every open Dependabot PR into ONE combined branch + one PR, so the
# expensive post-merge checks (perf gate, prod deploy) run a single time instead
# of once per PR. Cherry-picks each PR onto a fresh branch off main (linear
# history → the combined PR can be rebase-merged, no squash needed). Bumps that
# touch different files combine cleanly; same-file lockfile conflicts are skipped
# and listed in the PR body — re-run this after the combined PR merges, or merge
# those few by hand. After merging the combined PR, run:
#   just close-dependabot-prs <combined-pr-number>
combine-dependabot:
    #!/usr/bin/env bash
    set -euo pipefail
    BASE="${DEPENDABOT_BASE:-main}"
    COMBINE_BRANCH="combined-deps"

    # Only tracked changes block us — untracked files (e.g. local plans/*.md)
    # ride along safely across the branch switch + cherry-picks.
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
        echo "ERROR: uncommitted tracked changes — commit or stash before combining (untracked files are fine)." >&2
        exit 1
    fi
    ORIG="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse HEAD)"
    trap 'git switch "$ORIG" >/dev/null 2>&1 || true' EXIT

    echo "==> Collecting open Dependabot PRs..."
    mapfile -t ROWS < <(gh pr list --state open --json number,headRefName,title,author -L 200 \
        --jq '.[] | select(.author.login=="app/dependabot") | "\(.number)\t\(.headRefName)\t\(.title)"')
    if [[ ${#ROWS[@]} -eq 0 ]]; then echo "No open Dependabot PRs — nothing to combine."; exit 0; fi
    echo "    Found ${#ROWS[@]} Dependabot PR(s)."

    echo "==> Rebuilding '${COMBINE_BRANCH}' from origin/${BASE}..."
    git fetch --quiet origin "$BASE"
    git switch -C "$COMBINE_BRANCH" "origin/${BASE}"

    included=(); skipped=()
    for row in "${ROWS[@]}"; do
        num="${row%%$'\t'*}"; rest="${row#*$'\t'}"
        branch="${rest%%$'\t'*}"; title="${rest##*$'\t'}"
        printf '==> #%s (%s): ' "$num" "$branch"
        if ! git fetch --quiet origin "$branch" 2>/dev/null; then
            echo "fetch failed — skipped"; skipped+=("#${num} — ${title} (fetch failed)"); continue
        fi
        if git cherry-pick "origin/${BASE}..origin/${branch}" >/dev/null 2>&1; then
            echo "picked"; included+=("#${num}")
        else
            git cherry-pick --abort >/dev/null 2>&1 || true
            echo "conflict — skipped"; skipped+=("#${num} — ${title} (conflict)")
        fi
    done

    if [[ ${#included[@]} -eq 0 ]]; then
        echo "Nothing cherry-picked cleanly — leaving nothing to push." >&2
        exit 1
    fi

    echo "==> Pushing '${COMBINE_BRANCH}'..."
    git push --force origin "$COMBINE_BRANCH"

    nums="${included[*]//#/}"   # bare PR numbers, space-separated
    body="Combines $(IFS=' '; echo "${included[*]}") into one PR so the post-merge checks run once instead of per-PR."$'\n\n'"## Included"$'\n'"$(printf '%s\n' "${included[@]}" | sed 's/^/- /')"$'\n'
    if [[ ${#skipped[@]} -gt 0 ]]; then
        body+=$'\n'"## Skipped (same-file conflicts — NOT in this PR; merge individually or re-run \`just combine-dependabot\` after this merges)"$'\n'"$(printf '%s\n' "${skipped[@]}" | sed 's/^/- /')"$'\n'
    fi
    body+=$'\n'"After merging this PR: \`just close-dependabot-prs <this-pr-number>\`"
    # Machine-readable marker so close-dependabot-prs closes ONLY the bundled PRs
    # (never the skipped ones, which still carry un-merged updates).
    body+=$'\n\n'"<!-- combined-includes: ${nums} -->"

    existing="$(gh pr list --head "$COMBINE_BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
    if [[ -n "$existing" ]]; then
        gh pr edit "$existing" --body "$body" >/dev/null
        echo "==> Updated combined PR #${existing}  (included ${#included[@]}, skipped ${#skipped[@]})"
    else
        gh pr create --base "$BASE" --head "$COMBINE_BRANCH" \
            --title "chore(deps): combined Dependabot updates" --body "$body"
        echo "==> Opened combined PR  (included ${#included[@]}, skipped ${#skipped[@]})"
    fi

# Close every open Dependabot PR after the combined PR has merged.
# Usage: just close-dependabot-prs 250
# Refuses unless PR 250 is actually merged, so you never drop unmerged updates.
close-dependabot-prs COMBINED:
    #!/usr/bin/env bash
    set -euo pipefail
    merged="$(gh pr view {{COMBINED}} --json merged --jq .merged 2>/dev/null || echo false)"
    if [[ "$merged" != "true" ]]; then
        echo "ERROR: PR #{{COMBINED}} is not merged yet — refusing to close Dependabot PRs." >&2
        exit 1
    fi
    # Close ONLY the PRs actually bundled into the combined PR — read the
    # machine-readable marker its body carries. Skipped/conflicting PRs are left
    # open because they still carry updates that never reached main.
    body="$(gh pr view {{COMBINED}} --json body --jq .body)"
    nums="$(printf '%s\n' "$body" | grep -oE 'combined-includes:[0-9 ]+' | head -1 | sed 's/combined-includes://')"
    if [[ -z "${nums// /}" ]]; then
        echo "ERROR: no 'combined-includes' marker in PR #{{COMBINED}} — was it made by 'just combine-dependabot'?" >&2
        exit 1
    fi
    for n in $nums; do
        gh pr close "$n" --delete-branch \
            --comment "Superseded by combined Dependabot PR #{{COMBINED}} (merged). Closed to avoid a redundant post-merge run." \
            && echo "closed #$n"
    done
    echo "Done. Any Dependabot PRs left open were NOT in the bundle (conflicts) — handle those separately."

# Regenerate the hash-pinned vision lockfiles from requirements.txt INSIDE the
# runtime image (python:3.14-slim) so resolution + hashes match production
# exactly. requirements.txt / requirements-dev.txt stay the human-edited source
# (Dependabot watches them); run this after any bump so the locks don't drift.
lock-vision:
    #!/usr/bin/env bash
    set -euo pipefail
    # pip-tools pinned so output is byte-identical to the CI drift-guard.
    docker run --rm -v "$PWD":/repo -w /repo python:3.14-slim bash -c '
      set -e
      pip install --quiet --root-user-action=ignore pip-tools==7.5.3
      pip-compile --quiet --generate-hashes --allow-unsafe --strip-extras \
        --output-file apps/vision/requirements.lock apps/vision/requirements.txt
      pip-compile --quiet --generate-hashes --allow-unsafe --strip-extras \
        --output-file apps/vision/requirements-dev.lock \
        apps/vision/requirements.txt apps/vision/requirements-dev.txt
    '
    echo "Regenerated apps/vision/requirements.lock + requirements-dev.lock"
