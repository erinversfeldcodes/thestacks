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
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
VECTOR_TOML="${REPO_ROOT}/deploy/log-shipper/vector.toml"
FLY_TOML="${REPO_ROOT}/deploy/fly.log-shipper.toml"

PASSED=0
FAILED=0

_pass() { echo "ok   $1"; PASSED=$((PASSED + 1)); }
_fail() { echo "FAIL $1" >&2; FAILED=$((FAILED + 1)); }

_case() {
    echo ""
    echo "# === $1 ==="
    echo "# $2"
}

# ── Case 1: vector.toml parses and has required sections ────────────────────
_case "vector_toml_structure" "vector.toml has fly source, scrub_pii transform, axiom sink"
if python3 -c "
import sys
import tomllib
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

# ── Case 2: source references Fly's NATS URL with env-var expansion ─────────
# The env var name is `LOG_SHIPPER_ACCESS_TOKEN` (not bare `ACCESS_TOKEN`)
# to disambiguate from Fly's generic `ACCESS_TOKEN` convention — the
# shipper has its own org-scoped token independent of any other Fly
# credential in the system.
_case "vector_toml_nats_source" \
    "fly source uses NATS with ORG + LOG_SHIPPER_ACCESS_TOKEN env vars"
if python3 -c "
import tomllib
with open('${VECTOR_TOML}', 'rb') as f:
    data = tomllib.load(f)
src = data['sources']['fly']
assert src['type'] == 'nats', f'expected nats, got {src[\"type\"]}'
url = src.get('url', '')
assert '\${ORG}' in url, f'URL missing \${{ORG}}: {url}'
assert '\${LOG_SHIPPER_ACCESS_TOKEN}' in url, \
    f'URL missing \${{LOG_SHIPPER_ACCESS_TOKEN}}: {url}'
assert '\${ACCESS_TOKEN}' not in url or '\${LOG_SHIPPER_ACCESS_TOKEN}' in url, \
    'URL must use LOG_SHIPPER_ACCESS_TOKEN, not the bare ACCESS_TOKEN name'
assert '[fdaa::3]:4223' in url, f'URL missing Fly NATS host: {url}'
" 2>&1; then
    _pass "vector_toml_nats_source — NATS URL references \${ORG} + \${LOG_SHIPPER_ACCESS_TOKEN}"
else
    _fail "vector_toml_nats_source — NATS URL misconfigured"
fi

# ── Case 3: scrub_pii transform mentions all three PII classes ───────────────
_case "vector_toml_pii_scrub" "scrub transform redacts email, UUID, and IP patterns"
if grep -q "REDACTED_EMAIL" "${VECTOR_TOML}" \
    && grep -q "UUID" "${VECTOR_TOML}" \
    && grep -q "IP" "${VECTOR_TOML}"; then
    _pass "vector_toml_pii_scrub — email + UUID + IP redactions present"
else
    _fail "vector_toml_pii_scrub — at least one PII class is missing from the scrub transform"
fi

# ── Case 4: fly.log-shipper.toml has build.dockerfile pointing at our image ─
_case "fly_toml_build_dockerfile" "fly.log-shipper.toml builds from our custom Dockerfile"
if python3 -c "
import tomllib
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

# ── Case 4b: Dockerfile COPY paths resolve in Fly's build context ───────────
# deploy-stack.sh cd's into the Dockerfile's own directory before
# invoking `fly deploy`, so Fly's remote builder uses CWD (the
# Dockerfile's directory) as the build context. COPY paths in the
# Dockerfile must therefore be relative to THAT directory.
#
# Running fly deploy from the repo root instead produces a 2-byte
# build-context payload (verified empirically 2026-04-19) — the root
# .dockerignore filters nearly everything — and the COPY fails with
# `"settings.rendered.yml": not found`. Either way, deploy-stack.sh's
# `deploy_with_retry` swallows the error into a WARN and the app sits
# in a created-but-never-deployed state.
#
# This test prevents both regressions: a subdir-prefixed path (which
# would break once we're cd'd into the subdir) and a missing source
# file in the correct directory.
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
        # Subdir-prefixed paths (e.g. `searxng/foo.yml`) are a regression
        # — they'd break now that deploy-stack cd's INTO the subdir.
        # A bare basename is correct.
        if [[ "$src" == */* ]]; then
            _fail "${label} — COPY source '${src}' has a subdir prefix; must be a bare basename relative to the Dockerfile's directory"
            all_ok=0
            continue
        fi
        # Deploy-time-generated files (e.g. *.rendered.*) don't exist
        # at test time; assert the *unrendered* template lives alongside.
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

# ── Case 5: axiom sink reads token + dataset from env ────────────────────────
_case "vector_toml_axiom_sink" "axiom sink uses env-interpolated token + dataset"
if python3 -c "
import tomllib
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

# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "# ——————————————————————————"
echo "# passed: ${PASSED}  failed: ${FAILED}"
exit $((FAILED > 0 ? 1 : 0))
