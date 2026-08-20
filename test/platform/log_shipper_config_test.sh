#!/usr/bin/env bash
# test/platform/log_shipper_config_test.sh — smoke tests for the log-
# shipper config files.
#
# Validates:
#   - deploy/log-shipper/vector.toml parses as TOML and has the required
#     sections + sinks
#   - deploy/fly.log-shipper.toml parses as TOML and points at the
#     expected build context
#   - the scrub transform's VRL source is present and mentions the
#     three PII classes we care about (email, UUID, IP)
#
# The deep sanity check (`vector validate`) requires the vector binary
# and is deferred to the deploy script's in-container health probe — if
# VRL is syntactically wrong Vector fails at /health and the script
# bails. This test catches the TOML-level breakages that would hide a
# deploy-time bug behind a slower failure.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/python.sh"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
VECTOR_TOML="${REPO_ROOT}/deploy/log-shipper/vector.toml"
FLY_TOML="${REPO_ROOT}/deploy/fly.log-shipper.toml"

PASSED=0
FAILED=0

_pass() { echo "ok   $1"; PASSED=$((PASSED + 1)); }
_fail() { echo "FAIL $1" >&2; FAILED=$((FAILED + 1)); }

# `tomllib` is stdlib only from 3.11; macOS ships 3.9 as /usr/bin/python3, and
# a bare shell (CI runner, git hook) resolves python3 to that one. Every TOML
# assertion below then dies in the interpreter and is recorded as a config
# failure — the suite reports a broken vector.toml when the config is fine.
# Pick an interpreter that can actually parse TOML, the way the rollback
# composite suite picks one that can import yaml.
_TOML_PRELUDE='
try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    import tomli as tomllib
'

_pick_toml_python() {
    pick_python "$_TOML_PRELUDE" "stacks-log-shipper-test-venv" "tomli" \
        "$REPO_ROOT/apps/vision/.venv/bin/python3"
}

TOML_PYTHON="$(_pick_toml_python || true)"
if [[ -z "$TOML_PYTHON" ]]; then
    echo "FATAL: no Python interpreter that can parse TOML; cannot validate the configs" >&2
    echo "       (tried .venv-tools, scripts/mcp/.venv, apps/vision/.venv, system" >&2
    echo "        python3, and an ephemeral venv with tomli)" >&2
    exit 1
fi

_case() {
    echo ""
    echo "# === $1 ==="
    echo "# $2"
}

_case "vector_toml_structure" "vector.toml has fly source, scrub_pii transform, axiom sink"
if "$TOML_PYTHON" -c "
import sys
${_TOML_PRELUDE}
with open('${VECTOR_TOML}', 'rb') as f:
    data = tomllib.load(f)
missing = []
for key in ['sources.fly', 'transforms.scrub_pii', 'sinks.axiom']:
    section, name = key.split('.')
    if section not in data or name not in data[section]:
        missing.append(key)
if missing:
    print('missing:', ','.join(missing))
    sys.exit(1)
" 2>&1; then
    _pass "vector_toml_structure — all three top-level blocks present"
else
    _fail "vector_toml_structure — missing required blocks"
fi

_case "vector_toml_nats_source" \
    "fly source connects to Fly NATS with user_password auth"
if "$TOML_PYTHON" -c "
${_TOML_PRELUDE}
with open('${VECTOR_TOML}', 'rb') as f:
    data = tomllib.load(f)
src = data['sources']['fly']
assert src['type'] == 'nats', f'expected nats, got {src[\"type\"]}'
url = src.get('url', '')
assert '[fdaa::3]:4223' in url, f'URL missing Fly NATS host: {url}'
assert '@' not in url, f'URL must not embed user:pass@ (Vector ignores it): {url}'
auth = src.get('auth', {})
assert auth.get('strategy') == 'user_password', \
    f'auth.strategy must be user_password, got {auth.get(\"strategy\")!r}'
up = auth.get('user_password', {})
assert '\${ORG}' in up.get('user', ''), \
    f'auth.user_password.user must interpolate \${{ORG}}, got {up.get(\"user\")!r}'
assert '\${LOG_SHIPPER_ACCESS_TOKEN}' in up.get('password', ''), \
    f'auth.user_password.password must interpolate \${{LOG_SHIPPER_ACCESS_TOKEN}}, got {up.get(\"password\")!r}'
" 2>&1; then
    _pass "vector_toml_nats_source — NATS source uses explicit user_password auth with ORG + LOG_SHIPPER_ACCESS_TOKEN"
else
    _fail "vector_toml_nats_source — NATS source misconfigured; Vector will reject auth"
fi

_case "vector_toml_pii_scrub" "scrub transform redacts email, UUID, and IP patterns"
if grep -q "REDACTED_EMAIL" "${VECTOR_TOML}" \
    && grep -q "UUID" "${VECTOR_TOML}" \
    && grep -q "IP" "${VECTOR_TOML}"; then
    _pass "vector_toml_pii_scrub — email + UUID + IP redactions present"
else
    _fail "vector_toml_pii_scrub — at least one PII class is missing from the scrub transform"
fi

_case "fly_toml_build_dockerfile" "fly.log-shipper.toml builds from our custom Dockerfile"
if "$TOML_PYTHON" -c "
${_TOML_PRELUDE}
with open('${FLY_TOML}', 'rb') as f:
    data = tomllib.load(f)
assert data['build']['dockerfile'] == 'log-shipper/Dockerfile', \
    f'expected log-shipper/Dockerfile, got {data[\"build\"][\"dockerfile\"]}'
assert data['app'] == 'thestacks-log-shipper', f'unexpected app name: {data[\"app\"]}'
assert data['env']['ORG'], 'ORG must be set in [env]'
" 2>&1; then
    _pass "fly_toml_build_dockerfile — points at deploy/log-shipper/Dockerfile"
else
    _fail "fly_toml_build_dockerfile — build.dockerfile or app name wrong"
fi

_check_dockerfile_copy_paths() {
    local dockerfile="$1"
    local label="$2"
    local dir
    dir="$(dirname "$dockerfile")"
    local sources
    sources="$(grep -E '^[[:space:]]*COPY[[:space:]]' "$dockerfile" | awk '{print $2}')"
    if [[ -z "$sources" ]]; then
        _fail "${label} — no COPY lines found"
        return
    fi
    local all_ok=1
    while IFS= read -r src; do
        if [[ "$src" == */* ]]; then
            _fail "${label} — COPY source '${src}' has a subdir prefix; must be a bare basename relative to the Dockerfile's directory"
            all_ok=0
            continue
        fi
        if [[ "$src" == *.rendered.* ]]; then
            local unrendered="${src/.rendered/}"
            if [[ ! -e "${dir}/${unrendered}" ]]; then
                _fail "${label} — ${dir}/${unrendered} template missing (needed to produce ${src} at deploy time)"
                all_ok=0
            fi
            continue
        fi
        if [[ ! -e "${dir}/${src}" ]]; then
            _fail "${label} — ${dir}/${src} missing (COPY source)"
            all_ok=0
        fi
    done <<< "$sources"
    if [[ "$all_ok" -eq 1 ]]; then
        _pass "${label} — every COPY source resolves relative to the Dockerfile's directory"
    fi
}

_case "dockerfile_copy_paths_resolve_in_build_context" \
    "Dockerfile COPY sources resolve relative to the Dockerfile's own directory"
_check_dockerfile_copy_paths \
    "${REPO_ROOT}/deploy/log-shipper/Dockerfile" \
    "log-shipper Dockerfile"
_check_dockerfile_copy_paths \
    "${REPO_ROOT}/deploy/searxng/Dockerfile" \
    "searxng Dockerfile"

_case "vector_toml_api_enabled" \
    "[api] block enables /health on :8686 for Fly's health check"
if "$TOML_PYTHON" -c "
${_TOML_PRELUDE}
with open('${VECTOR_TOML}', 'rb') as f:
    data = tomllib.load(f)
api = data.get('api', {})
assert api.get('enabled') is True, f'[api] must have enabled=true, got {api}'
address = api.get('address', '')
assert '8686' in address, f'[api] address must bind :8686 so fly check hits it, got {address!r}'
" 2>&1; then
    _pass "vector_toml_api_enabled — [api] block present, enabled, binding :8686"
else
    _fail "vector_toml_api_enabled — /health would not respond; Fly would suspend the app"
fi

_case "vector_toml_axiom_sink" "axiom sink uses env-interpolated token + dataset"
if "$TOML_PYTHON" -c "
${_TOML_PRELUDE}
with open('${VECTOR_TOML}', 'rb') as f:
    data = tomllib.load(f)
sink = data['sinks']['axiom']
assert sink['type'] == 'axiom', f'expected axiom, got {sink[\"type\"]}'
assert '\${AXIOM_TOKEN}' in sink.get('token', ''), 'token must interpolate AXIOM_TOKEN'
assert '\${AXIOM_DATASET}' in sink.get('dataset', ''), 'dataset must interpolate AXIOM_DATASET'
assert sink['inputs'] == ['scrub_pii'], f'axiom sink must read from scrub_pii, got {sink[\"inputs\"]}'
" 2>&1; then
    _pass "vector_toml_axiom_sink — axiom sink wired to scrub_pii via env-var secrets"
else
    _fail "vector_toml_axiom_sink — axiom sink misconfigured"
fi

echo ""
echo "# ——————————————————————————"
echo "# passed: ${PASSED}  failed: ${FAILED}"
exit $((FAILED > 0 ? 1 : 0))
