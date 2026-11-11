#!/usr/bin/env bash

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -f "$REPO_ROOT/.versions" ]]; then
    # shellcheck source=../.versions
    source "$REPO_ROOT/.versions"
fi

if [[ -f "$REPO_ROOT/.env" && -z "${CI:-}" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'


# ⛔ THE PROOF A BROWSER WOULD HAVE, for the stack at $1. Every login below is a
# state-changing request and is refused without a double-submit proof: the
# readable `stacks_csrf` cookie echoed in `X-CSRF-Token`.
#
# ⚠️ THE COST OF NOT DOING THIS WAS TWO SECURITY SCANS GOING DARK. The jwt_tool
# and IDOR lanes each log in to obtain a token; unproven, both got 403, found no
# token, and reported `SKIP: … could not obtain JWT` / `SKIP: IDOR — could not
# authenticate both seed users`. A scan that skips is not a clean scan, which
# the jwt_tool lane's own comment says three lines from where it skips.
_csrf_proof_for() {
    CSRF_JAR="$(mktemp)"
    curl -sf -o /dev/null --cookie-jar "${CSRF_JAR}" --max-time 15 "$1/" || true
    CSRF_PROOF="$(awk '$6 == "stacks_csrf" { print $7 }' "${CSRF_JAR}" 2>/dev/null | tail -1)"
    if [[ -z "${CSRF_PROOF}" ]]; then
        echo "WARN: no stacks_csrf cookie from $1/ — every login below will be refused 403" >&2
    fi
}

pass() { echo -e "${GREEN}${BOLD}PASS${RESET} $1"; }
fail() { echo -e "${RED}${BOLD}FAIL${RESET} $1"; }
SKIPPED=()
skip() {
    echo -e "${YELLOW}${BOLD}SKIP${RESET} $1"
    SKIPPED+=("$1")
}

run_group() {
    local name="$1"; shift
    echo -e "\n${CYAN}${BOLD}=== $name ===${RESET}"

    # The group's own output is teed so that a gate which skipped INTERNALLY can
    # be relayed into the skip register below. Several scripts decide for
    # themselves that a tool is absent and echo "SKIP: …" inline — before this,
    # those never reached the summary, so a run could end green with no record
    # that the container-image gate, or trufflehog, had not run at all. A gate
    # that did not run is not a gate that passed, and the summary is the only
    # place a reader looks.
    #
    # A pipe with `PIPESTATUS`, not process substitution: the command's own exit
    # status has to survive, AND the log has to be complete before it is read.
    # Process substitution gives no guarantee the tee has flushed by the time the
    # command returns, and an unflushed log reads as "nothing was skipped" —
    # which is the failure this exists to prevent, arrived at a different way.
    # An explicit XXXXXX template. `mktemp -t <name>` is a BSD spelling that GNU
    # coreutils rejects with "too few X's in template" — and it failed quietly
    # enough that the relay below read an empty path and reported nothing
    # skipped, which is this function's own defect class arrived at from the
    # other side. If the file cannot be made, say so rather than relay nothing.
    local log status
    log="$(mktemp "${TMPDIR:-/tmp}/stacks-ci-group.XXXXXX")" || log=""

    if [[ -z "$log" ]]; then
        echo "WARN: could not create a temp file, so internal SKIPs from this group will not be relayed" >&2
        "$@"
        status=$?
    else
        "$@" 2>&1 | tee "$log"
        status="${PIPESTATUS[0]}"

        while IFS= read -r line; do
            [[ -n "$line" ]] && skip "$name — ${line#SKIP: }"
        done < <(grep '^[[:space:]]*SKIP:' "$log" 2>/dev/null | sed 's/^[[:space:]]*//')

        rm -f "$log"
    fi

    if [[ $status -eq 0 ]]; then
        pass "$name"
    else
        fail "$name"
        return 1
    fi
}

if [[ $# -eq 0 ]]; then
    CI_GROUPS=(elixir elm rust python proto dbt security squawk platform licenses)
else
    CI_GROUPS=("$@")
fi

has_group() {
    local target="$1"
    for g in "${CI_GROUPS[@]}"; do [[ "$g" == "$target" ]] && return 0; done
    return 1
}

FAILED=()

if has_group elixir; then
    if ! run_group "elixir: version-drift" bash scripts/check-version-drift.sh; then
        # A drifted toolchain means every mix invocation below compiles _build
        # with the WRONG Elixir/OTP — beams the pinned shell then cannot load
        # (corrupt atom table, Regex struct mismatches). Abort before the first
        # compile instead of failing seven gates and poisoning the tree.
        echo -e "\n${RED}${BOLD}ABORT${RESET} elixir toolchain drifted — refusing to compile with it."
        echo "      Run via the pinned shell (just run just ci ...) or fix PATH/direnv, then retry."
        echo "      If mix already ran on the wrong toolchain: rm -rf _build and rebuild pinned."
        exit 1
    fi

    echo -e "\n${CYAN}${BOLD}=== elixir: deps ===${RESET}"
    mix deps.get

    echo -e "\n${CYAN}${BOLD}=== elixir: proto.sync ===${RESET}"
    (cd apps/core && mix proto.sync)

    if ! run_group "elixir: lint" bash scripts/lint-elixir.sh; then FAILED+=(elixir-lint); fi
    if ! run_group "elixir: test" bash scripts/test-elixir.sh; then FAILED+=(elixir-test); fi
fi

if has_group elm; then
    echo -e "\n${CYAN}${BOLD}=== elm: deps ===${RESET}"
    (cd frontend && npm ci)

    if ! run_group "elm: lint" bash scripts/lint-elm.sh; then FAILED+=(elm-lint); fi
    if ! run_group "elm: test" bash scripts/test-elm.sh; then FAILED+=(elm-test); fi
fi

if has_group rust; then
    if ! run_group "rust: lint" bash scripts/lint-rust.sh; then FAILED+=(rust-lint); fi
    if ! run_group "rust: test" bash scripts/test-rust.sh; then FAILED+=(rust-test); fi
fi

if has_group python; then
    echo -e "\n${CYAN}${BOLD}=== python: deps ===${RESET}"
    VENV_PIP="$REPO_ROOT/apps/vision/.venv/bin/pip"
    PIP="${VENV_PIP:-$(command -v pip3 || command -v pip)}"
    (cd apps/vision && "$PIP" install -r requirements.txt -r requirements-dev.txt)

    if ! run_group "python: lint" bash scripts/lint-python.sh; then FAILED+=(python-lint); fi
    if ! run_group "python: test" bash scripts/test-python.sh; then FAILED+=(python-test); fi
fi

if has_group proto; then
    if ! run_group "proto: lint" bash scripts/lint-proto.sh; then FAILED+=(proto-lint); fi
fi

if has_group dbt; then
    echo -e "\n${CYAN}${BOLD}=== dbt: deps ===${RESET}"
    PIP="$(command -v pip3 || command -v pip)"
    "$PIP" install dbt-postgres sqlfluff sqlfluff-templater-dbt

    if ! run_group "dbt: lint sql" bash scripts/lint-sql.sh; then FAILED+=(dbt-lint-sql); fi
    if ! run_group "dbt: run + test" bash scripts/test-dbt.sh; then FAILED+=(dbt-test); fi
    if ! run_group "dbt: checkpoint" bash scripts/lint-dbt.sh; then FAILED+=(dbt-checkpoint); fi
fi

if has_group security; then
    if ! run_group "security: scans" bash scripts/security.sh; then FAILED+=(security); fi
fi

if has_group squawk; then
    echo -e "\n${CYAN}${BOLD}=== squawk: migration lint ===${RESET}"
    bash scripts/security-squawk.sh
    _squawk_rc=$?
    case "$_squawk_rc" in
        0) pass "squawk: migration lint" ;;
        2) skip "squawk: migration lint — 0 migrations inspected (nothing was checked)" ;;
        *) fail "squawk: migration lint"; FAILED+=(squawk) ;;
    esac
fi

if has_group platform; then
    # The shell suites over the deploy/rollback/migration-safety scripts. They
    # run their own per-suite watchdog, which needs a timeout binary — present
    # in the pinned shell, absent from a bare macOS one, where run_all.sh says
    # so on stdout.
    if ! run_group "platform: shell suites" bash test/platform/run_all.sh; then
        FAILED+=(platform)
    fi
    # Every script in scripts/ has a caller (or an allowlisted reason), and the
    # generated inventory in scripts/README.md is current.
    if ! run_group "platform: script wiring" bash scripts/check-script-wiring.sh; then
        FAILED+=(platform-script-wiring)
    fi
    # The project-tools MCP server's own suite — orphaned once, never again.
    if ! run_group "platform: mcp server tests" bash scripts/test-mcp.sh; then
        FAILED+=(platform-mcp)
    fi
fi

if has_group e2e; then
    if ! run_group "e2e: playwright" bash scripts/test-e2e.sh; then FAILED+=(e2e); fi
fi

if has_group smoke; then
    if [[ -z "${SMOKE_URL:-}" ]]; then
        echo -e "${RED}${BOLD}ERROR${RESET} smoke: SMOKE_URL is not set"
        FAILED+=(smoke)
    elif [[ -z "${SCRAPER_HMAC_SECRET:-}" ]]; then
        echo -e "${RED}${BOLD}ERROR${RESET} smoke: SCRAPER_HMAC_SECRET is not set"
        FAILED+=(smoke)
    else
        if ! run_group "smoke: circuit breakers" \
            bash scripts/smoke-circuit-breakers.sh "${SMOKE_URL}"; then
            FAILED+=(smoke)
        fi
    fi
fi

if has_group licenses; then
    if ! run_group "licenses: compliance" bash scripts/check-licenses.sh; then FAILED+=(licenses); fi
fi

echo ""
if [[ ${#FAILED[@]} -eq 0 ]]; then
    if [[ ${#SKIPPED[@]} -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}All checks passed.${RESET}"
    else
        echo -e "${GREEN}${BOLD}No failures.${RESET}"
    fi
else
    echo -e "${RED}${BOLD}Failed checks:${RESET}"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
fi
if [[ ${#SKIPPED[@]} -ne 0 ]]; then
    echo -e "${YELLOW}${BOLD}Skipped (inspected nothing — not evidence of anything):${RESET}"
    for s in "${SKIPPED[@]}"; do echo "  - $s"; done
fi

if [[ $# -eq 0 ]] && [[ ${#FAILED[@]} -eq 0 ]] && [[ -n "${FLY_API_TOKEN:-}" ]]; then
    _branch="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "preview")}"
    # Shared derivation (C): honours the optional PREVIEW_SUFFIX
    # env var (set by CI, unset locally) so this block and the deploy/cleanup
    # scripts always agree on the preview resource names.
    # shellcheck source=scripts/lib/preview-names.sh
    source "$REPO_ROOT/scripts/lib/preview-names.sh"
    derive_preview_names "$_branch"
    _core_app="${PREVIEW_CORE_APP}"
    _core_url="https://${_core_app}.fly.dev"
    _neon_branch="${PREVIEW_NEON_BRANCH}"

    echo -e "\n${CYAN}${BOLD}=== deploy: stack + warmup ===${RESET}"
    if bash scripts/deploy-preview.sh; then

        echo -e "\n${CYAN}${BOLD}=== deploy: E2E ===${RESET}"

        echo "==> Warming Fly.io machines and Neon database..."
        _warm_pids=()
        for i in {1..20}; do
            curl -sf --max-time 5 "${_core_url}/api/health" >/dev/null 2>&1 &
            _warm_pids+=("$!")
        done
        for i in {1..10}; do
            curl -sf --max-time 10 "${_core_url}/login" >/dev/null 2>&1 &
            _warm_pids+=("$!")
        done
        for i in {1..5}; do
            _csrf_proof_for "${_core_url}"
            curl -sf --max-time 30 "${_core_url}/api/auth/login" \
                -b "${CSRF_JAR}" -H "X-CSRF-Token: ${CSRF_PROOF}" \
                -H "Content-Type: application/json" \
                -d '{"email":"owner@thestacks.app","password":"dev-password-123"}' \
                >/dev/null 2>&1 &
            _warm_pids+=("$!")
        done
        for i in {1..3}; do
            _db_warm_token="$(curl -sf --max-time 30 "${_core_url}/api/auth/login" \
                -b "${CSRF_JAR}" -H "X-CSRF-Token: ${CSRF_PROOF}" \
                -H "Content-Type: application/json" \
                -d '{"email":"owner@thestacks.app","password":"dev-password-123"}' \
                2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"
            if [[ -n "${_db_warm_token}" ]]; then
                curl -sf --max-time 30 "${_core_url}/api/catalogue?per_page=20" \
                    -H "Authorization: Bearer ${_db_warm_token}" >/dev/null 2>&1 || true
            fi
        done
        for pid in "${_warm_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
        sleep 2

        (while true; do
            curl -sf --max-time 5 "${_core_url}/api/health" >/dev/null 2>&1 || true
            sleep 10
        done) &
        _keep_alive_pid=$!

        _fly_logs="$(mktemp)"
        (fly logs --app "${_core_app}" 2>&1) > "${_fly_logs}" &
        _fly_logs_pid=$!

        # ⛔ WHAT THE DEPLOY DECIDED, HANDED TO THE SUITE THAT HAS TO KNOW IT.
        # The preview runs a raised `:auth` ceiling and rate-limit.spec.ts
        # sizes its flood from it. The old handoff was `$GITHUB_ENV`, which
        # does not exist here, so the spec fell back to a default BELOW the
        # real ceiling, never saw a 429, and reported brute-force protection
        # absent — a security verdict manufactured by a missing variable.
        # Refuse rather than run the suite half-informed.
        # shellcheck source=lib/e2e-handoff.sh
        source "${REPO_ROOT}/scripts/lib/e2e-handoff.sh"
        e2e_handoff_load
        if [[ -z "${E2E_AUTH_RATE_LIMIT:-}" ]]; then
            echo -e "${RED}${BOLD}FAIL${RESET} deploy: the preview deploy left no E2E handoff at $(e2e_handoff_path) — rate-limit.spec.ts would size its flood from a guess, and a flood that falls short of the ceiling reads as absent brute-force protection. See scripts/lib/e2e-handoff.sh." >&2
            FAILED+=(deploy-e2e-handoff)
        fi

        # ⛔ The same enforcement the workflow applies: without
        # E2E_EXPECT_EMAIL_DELIVERY the email-budget gate is a permanent silent
        # skip, and this path deploys a fresh stack whose send budget is intact.
        if ! CI=1 E2E_SERVICES=none E2E_EXPECT_EMAIL_DELIVERY=1 BASE_URL="${_core_url}" \
                run_group "deploy: e2e" bash scripts/test-e2e.sh; then
            FAILED+=(deploy-e2e)
        fi

        # ⛔ REPEATABILITY, AND IT BELONGS HERE RATHER THAN BESIDE THE LOCAL E2E.
        # The subject is state a run LEAVES BEHIND on a shared stack, so it needs
        # a persistent deployed target — the local run tears its stack down and
        # cannot exhibit the defect at all.
        #
        # ⚠️ Why it is worth two extra runs of two spec files: without it a
        # failure COUNT is not a measurement. This suite reported 44, 34, 18, 13
        # and 15 failures across one session, and part of that was real
        # improvement while part was residue from the run before — which cannot
        # be separated afterwards. The standing rule that every failure gets
        # fixed silently assumes a stable denominator.
        if ! CI=1 BASE_URL="${_core_url}" \
                run_group "deploy: e2e repeatability" \
                bash scripts/check-e2e-repeatability.sh; then
            FAILED+=(deploy-e2e-repeatability)
        fi

        kill "${_keep_alive_pid}" 2>/dev/null || true
        kill "${_fly_logs_pid}" 2>/dev/null || true
        wait "${_fly_logs_pid}" 2>/dev/null || true
        echo ""
        echo "--- Core app logs during E2E (last 200 lines) ---"
        tail -200 "${_fly_logs}" || true
        echo "--- End core logs ---"
        rm -f "${_fly_logs}"

        if [[ -n "${SCRAPER_HMAC_SECRET:-}" ]]; then
            if ! SMOKE_URL="${_core_url}" \
                    run_group "deploy: smoke" \
                    bash scripts/smoke-circuit-breakers.sh "${_core_url}"; then
                true  # advisory — circuit breaker failures don't gate the build
            fi
        else
            echo "SKIP deploy: smoke — SCRAPER_HMAC_SECRET not set"
        fi

        echo -e "\n${CYAN}${BOLD}=== deploy: security-live ===${RESET}"

        # ⚠️ The DAEMON, not the binary. `command -v docker` succeeds whenever the
        # client is installed, which it is on any developer machine with Docker
        # Desktop or colima — while the daemon may well be stopped. The scan
        # then fails with "Cannot connect to the Docker daemon", its output
        # contains no "FAIL-NEW: 0", and the branch below reported
        # **"ZAP baseline found new failures"**: a missing scanner announced as
        # a security finding.
        if docker info &>/dev/null; then
            echo "==> OWASP ZAP baseline scan..."
            zap_out="$(docker run --rm \
                --mount type=tmpfs,destination=/zap/wrk \
                ghcr.io/zaproxy/zaproxy:2.16.1 \
                zap-baseline.py -t "${_core_url}" 2>&1)" || true
            echo "${zap_out}"
            # ⛔ THREE OUTCOMES, NOT TWO, and collapsing them is what made the
            # message wrong. "Clean", "found something", and "did not run" are
            # different facts, and only the first two are about the application.
            if grep -q "FAIL-NEW: 0" <<< "${zap_out}"; then
                pass "deploy: ZAP baseline"
            elif grep -qE "FAIL-NEW: [0-9]+" <<< "${zap_out}"; then
                fail "deploy: ZAP baseline found new failures"
                FAILED+=(deploy-security)
            else
                # A scanner that did not run is not a clean scan — the ruling the
                # jwt_tool lane already states — but it is not a FINDING either.
                fail "deploy: ZAP did not run (no FAIL-NEW line in its output) — NOT a clean scan"
                FAILED+=(deploy-security)
            fi
        else
            echo "SKIP: docker daemon not reachable — skipping OWASP ZAP"
        fi

        if command -v nuclei &>/dev/null; then
            echo "==> Nuclei (jwt + misconfig)..."
            nuclei_out="$(nuclei -u "${_core_url}" \
                -tags jwt,misconfiguration \
                -severity medium,high,critical \
                -no-color -silent 2>&1)"
            nuclei_rc=$?
            echo "${nuclei_out}"
            # Same shape the jwt_tool lane had: this grepped for BADNESS, and a
            # scanner that never ran prints no "[high]" lines, so a crash or a
            # missing template directory reported clean. Prove it ran first.
            #
            # (ZAP above is the safe polarity — it greps for the SUCCESS marker
            # "FAIL-NEW: 0", so a crash yields no match and fails. Do not
            # "harmonise" these by copying the wrong one.)
            #
            # ⛔ The here-string is load-bearing, not a style choice. As
            # `echo "$out" | grep -q`, this failed OPEN: grep exits on its first
            # match, echo takes SIGPIPE, and under `pipefail` the pipeline
            # returns 141, so the `elif` goes FALSE and the lane printed
            # "Nuclei scan clean" on a critical finding. It needs a payload
            # larger than the pipe buffer with the match inside it — measured
            # at 300KB with the match first: rc=141, and with the match last:
            # rc=0. A scanner's output is routinely that large, and the bigger
            # the finding list the likelier the miss.
            if [[ ${nuclei_rc} -ne 0 ]]; then
                fail "deploy: Nuclei did not run (exit ${nuclei_rc}) — this is NOT a clean scan"
                FAILED+=(deploy-security)
            elif grep -qiE "\[critical\]|\[high\]" <<< "${nuclei_out}"; then
                fail "deploy: Nuclei found high/critical vulnerabilities"
                FAILED+=(deploy-security)
            else
                pass "deploy: Nuclei scan clean"
            fi
        else
            echo "SKIP: nuclei not installed (brew install nuclei)"
        fi

        if command -v jwt_tool &>/dev/null; then
            echo "==> jwt_tool..."
            _csrf_proof_for "${_core_url}"
            _jwt_resp="$(curl -sf "${_core_url}/api/auth/login" \
                -b "${CSRF_JAR}" -H "X-CSRF-Token: ${CSRF_PROOF}" \
                -H "Content-Type: application/json" \
                -d '{"email":"owner@thestacks.app","password":"dev-password-123"}' \
                2>/dev/null || true)"
            _jwt="$(echo "${_jwt_resp}" | python3 -c \
                "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"
            if [[ -n "${_jwt}" ]]; then
                # ⛔ THREE THINGS WERE WRONG HERE AT ONCE, and together they made
                # a lane that could not pass and could not fail honestly. All
                # three were measured against a local stack, not reasoned.
                #
                # 1. `-rh "Authorization: Bearer *JWT*"` with the token as the
                #    FIRST POSITIONAL found nothing: jwt_tool answered
                #    `Cannot find a valid JWT` and printed `None | [...] | None`.
                #    Its own usage says the token needs no positional "if in
                #    header/cookies" — so the header must carry the REAL token
                #    and there is no placeholder to substitute.
                # 2. It proxies to 127.0.0.1:8080 (Burp) BY DEFAULT. Without
                #    `-np` every request died with
                #    `ProxyError - check proxy is up`, so even a correct
                #    invocation never reached the target.
                # 3. ⚠️ **It exits 1 on a SUCCESSFUL run.** Measured: a bare
                #    `jwt_tool <token>` decodes the token, prints the claims, and
                #    returns 1. So `jwt_rc -ne 0` as the "did it run?" test can
                #    never be satisfied — which is why this lane went from
                #    silently skipping to deterministically failing and never
                #    passed in between.
                jwt_out="$(jwt_tool \
                    -t "${_core_url}/api/auth/me" \
                    -rh "Authorization: Bearer ${_jwt}" \
                    -np -X a 2>&1)"
                echo "${jwt_out}"

                # The colour codes have to go before anything is counted, or
                # every pattern below is matched against escape sequences.
                jwt_clean="$(sed -E $'s/\033\[[0-9;]*m//g' <<< "${jwt_out}")"
                # ⬜ ANTI-VACUITY: the number of tampered tokens it actually sent.
                # Zero means it found the token and attacked nothing, which reads
                # identically to a clean scan in every other respect.
                jwt_attacks="$(grep -cE 'Exploit: .*Response Code: [0-9]+' <<< "${jwt_clean}")"
                # ⛔ A FINDING IS A 2xx, NOT THE WORD "EXPLOIT". `grep -i EXPLOIT`
                # matched jwt_tool's own label for each attack it TRIED — the
                # four `"alg":"none"` variants print `Exploit: … Response Code:
                # 401`, all correctly refused. So the old check would have called
                # a perfectly defended stack vulnerable the moment the
                # invocation above started working. The result is in the code.
                jwt_accepted="$(grep -cE 'Exploit: .*Response Code: 2[0-9][0-9]' <<< "${jwt_clean}")"

                if grep -q "Traceback (most recent call last)" <<< "${jwt_clean}" \
                    || grep -q "\[ERROR\]" <<< "${jwt_clean}" \
                    || ! grep -q "^Original JWT:" <<< "${jwt_clean}" \
                    || [[ "${jwt_attacks}" -eq 0 ]]; then
                    fail "deploy: jwt_tool did not run (found-token=$(grep -c '^Original JWT:' <<< "${jwt_clean}"), attacks=${jwt_attacks}) — this is NOT a clean scan"
                    FAILED+=(deploy-security)
                elif [[ "${jwt_accepted}" -gt 0 ]]; then
                    fail "deploy: jwt_tool — ${jwt_accepted} of ${jwt_attacks} tampered tokens were ACCEPTED (2xx)"
                    FAILED+=(deploy-security)
                else
                    pass "deploy: jwt_tool clean — ${jwt_attacks} tampered tokens all refused"
                fi
            else
                # ⛔ Same ruling as the comment above: a scan that did not run is
                # not a clean scan, and "could not obtain JWT" is exactly how a
                # broken login looks from here.
                if [[ "${CI:-}" == "1" ]]; then
                    fail "deploy: jwt_tool could not obtain a JWT — NOT a clean scan"
                    FAILED+=(deploy-security)
                else
                    echo "SKIP: jwt_tool — could not obtain JWT"
                fi
            fi
        else
            echo "SKIP: jwt_tool not installed (run setup.sh)"
        fi

        echo "==> IDOR test (cross-user resource access)..."
        _u1="$(curl -sf "${_core_url}/api/auth/login" \
                -b "${CSRF_JAR}" -H "X-CSRF-Token: ${CSRF_PROOF}" \
            -H "Content-Type: application/json" \
            -d '{"email":"owner@thestacks.app","password":"dev-password-123"}' 2>/dev/null \
            | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" \
            2>/dev/null || true)"
        _u2="$(curl -sf "${_core_url}/api/auth/login" \
                -b "${CSRF_JAR}" -H "X-CSRF-Token: ${CSRF_PROOF}" \
            -H "Content-Type: application/json" \
            -d '{"email":"user@thestacks.app","password":"dev-password-456"}' 2>/dev/null \
            | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" \
            2>/dev/null || true)"
        if [[ -z "${_u1}" ]] || [[ -z "${_u2}" ]]; then
            # ⛔ A SECURITY CHECK THAT COULD NOT RUN IS NOT A PASS, and this
            # skipped silently through the exact failure it exists to catch:
            # once CSRF enforcement landed, both logins above were refused 403,
            # yielded no token, and this lane printed SKIP while the IDOR
            # cross-user DELETE went unexercised. Nothing in the run was red.
            #
            # ⚖️ The same ruling the jwt_tool lane already states three branches
            # down — "a scanner that did not run is NOT a clean scan" — applied
            # to its sibling. A target that genuinely lacks the seed users is a
            # real scenario, so the refusal is scoped to CI, where the stack is
            # freshly seeded and a missing seed user is itself a defect.
            if [[ "${CI:-}" == "1" ]]; then
                fail "deploy: IDOR could not authenticate the seed users — NOT a clean scan"
                FAILED+=(deploy-security)
            else
                echo "SKIP: IDOR — could not authenticate both seed users"
            fi
        else
            _placement="$(curl -sf "${_core_url}/api/bookshelves/library" \
                -H "Authorization: Bearer ${_u1}" 2>/dev/null \
                | python3 -c \
                    "import json,sys; d=json.load(sys.stdin); s=d.get('shelves',[]); p=[pl for sh in s for pl in sh.get('placements',[])]; print(p[0]['id'] if p else '')" \
                2>/dev/null || true)"
            if [[ -n "${_placement}" ]]; then
                # ⛔ THE PROOF IS WHAT KEEPS THIS TEST MEANINGFUL, not a
                # formality. This check treats 403 and 404 as "denied" — and a
                # request with no CSRF proof is refused with **403**. So without
                # the proof this assertion passes no matter what the
                # authorization layer does: it would report "IDOR cross-user
                # DELETE blocked (HTTP 403)" over a stack whose row-level checks
                # had been deleted entirely. The proof makes the 403 mean
                # authorization again.
                _idor_jar="$(mktemp)"
                curl -s -o /dev/null --cookie-jar "${_idor_jar}" --max-time 10 "${_core_url}/" || true
                _idor_proof="$(awk '$6 == "stacks_csrf" { print $7 }' "${_idor_jar}" 2>/dev/null | tail -1)"
                if [[ -z "${_idor_proof}" ]]; then
                    echo "FAIL idor: no stacks_csrf cookie, so a 403 below would not mean denied"
                    rm -f "${_idor_jar}"
                    exit 1
                fi
                _idor_code="$(curl -o /dev/null -s -w "%{http_code}" \
                    -X DELETE "${_core_url}/api/placements/${_placement}" \
                    -b "${_idor_jar}" \
                    -H "X-CSRF-Token: ${_idor_proof}" \
                    -H "Authorization: Bearer ${_u2}")"
                rm -f "${_idor_jar}"
                # Fail on anything that is not an explicit denial.
                #
                # This used to fail only on 200 — and a successful placement
                # DELETE returns **204** (`bookshelf_placement_controller.ex`),
                # so a genuine cross-user deletion printed
                # "IDOR cross-user DELETE blocked (HTTP 204)": a green tick for a
                # working exploit that had just destroyed the other reader's
                # placement. A connection failure (`000`) passed too.
                #
                # Only 403 and 404 mean "denied". Everything else is a finding.
                if [[ "${_idor_code}" == "403" || "${_idor_code}" == "404" ]]; then
                    pass "deploy: IDOR cross-user DELETE blocked (HTTP ${_idor_code})"
                else
                    fail "deploy: IDOR — cross-user DELETE returned HTTP ${_idor_code}, expected a denial"
                    FAILED+=(deploy-security)
                fi
            else
                echo "SKIP: IDOR — user1 has no placements in library"
            fi
        fi

    else
        fail "deploy: stack or warmup failed"
        FAILED+=(deploy)
    fi

    echo -e "\n${CYAN}${BOLD}=== deploy: cleanup ===${RESET}"
    bash scripts/cleanup-preview.sh \
        --branch "${_branch}" \
        --neon-branch-name "${_neon_branch}" || true
fi

if [[ ${#FAILED[@]} -ne 0 ]]; then
    exit 1
fi
