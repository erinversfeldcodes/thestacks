#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$REPO_ROOT/.env" && -z "${CI:-}" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

export PATH="${HOME}/.local/bin:${PATH}"

SEARXNG_APP="${SEARXNG_APP:-thestacks-searxng}"
SEARXNG_REGION="${SEARXNG_REGION:-iad}"
CONFIG_TOML="${REPO_ROOT}/deploy/fly.searxng.toml"
SETTINGS_TEMPLATE="${REPO_ROOT}/deploy/searxng/settings.yml"
SETTINGS_TMP="$(mktemp /tmp/searxng-settings-XXXXXX.yml)"
trap 'rm -f "${SETTINGS_TMP}"' EXIT

FLY_ACCESS_TOKEN="${FLY_ACCESS_TOKEN:-${FLY_API_TOKEN:-}}"
if [[ -z "${FLY_ACCESS_TOKEN:-}" ]]; then
    echo "ERROR: FLY_ACCESS_TOKEN (or FLY_API_TOKEN) is not set." >&2
    echo "       Export it before running this script." >&2
    exit 1
fi
export FLY_ACCESS_TOKEN

if [[ -z "${SEARXNG_SECRET_KEY:-}" ]]; then
    echo "ERROR: SEARXNG_SECRET_KEY is not set." >&2
    echo "       Generate one with: openssl rand -hex 32" >&2
    exit 1
fi

if ! command -v fly &>/dev/null; then
    echo "ERROR: flyctl is not installed." >&2
    echo "       Install with: scripts/install-flyctl.sh  or  brew install flyctl" >&2
    exit 1
fi

echo "==> Deploy SearXNG (app: ${SEARXNG_APP}, region: ${SEARXNG_REGION})"

echo "==> Rendering settings.yml from template..."
sed "s|__SEARXNG_SECRET_KEY__|${SEARXNG_SECRET_KEY}|g" \
    "${SETTINGS_TEMPLATE}" > "${SETTINGS_TMP}"

echo "==> Ensuring Fly app '${SEARXNG_APP}' exists..."
if ! fly apps list --json 2>/dev/null \
        | python3 -c "import json,sys; apps=json.load(sys.stdin); exit(0 if any(a['Name']=='"${SEARXNG_APP}"' for a in apps) else 1)" 2>/dev/null; then
    fly apps create "${SEARXNG_APP}" --machines 2>&1 || true
    echo "    App created."
else
    echo "    App already exists — skipping create."
fi

echo "==> Ensuring volume 'searxng_settings' exists in ${SEARXNG_REGION}..."
if ! fly volumes list --app "${SEARXNG_APP}" --json 2>/dev/null \
        | python3 -c "import json,sys; vols=json.load(sys.stdin); exit(0 if vols else 1)" 2>/dev/null; then
    fly volumes create searxng_settings \
        --app "${SEARXNG_APP}" \
        --region "${SEARXNG_REGION}" \
        --size 1 \
        --yes 2>&1
    echo "    Volume created."
else
    echo "    Volume already exists — skipping create."
fi

echo "==> Deploying ${SEARXNG_APP}..."
fly deploy \
    --app "${SEARXNG_APP}" \
    --config "${CONFIG_TOML}" \
    --region "${SEARXNG_REGION}" \
    --yes

echo "PASS deploy: ${SEARXNG_APP} deployed"

echo "==> Setting SEARXNG_SECRET_KEY secret..."
fly secrets set \
    SEARXNG_SECRET_KEY="${SEARXNG_SECRET_KEY}" \
    --app "${SEARXNG_APP}" \
    --stage

echo "PASS secrets: SEARXNG_SECRET_KEY staged"

echo "==> Uploading rendered settings.yml to /etc/searxng/settings.yml..."
fly ssh sftp shell --app "${SEARXNG_APP}" <<EOF
put ${SETTINGS_TMP} /etc/searxng/settings.yml
EOF
echo "PASS upload: settings.yml uploaded"

rm -f "${SETTINGS_TMP}"

echo ""
echo "==> SearXNG is live (internal only)."
echo "    Internal URL: http://${SEARXNG_APP}.internal:8080"
echo "    Verify:       fly ssh console -a ${SEARXNG_APP}"
echo "    Then run:     curl 'localhost:8080/search?q=hobbit&format=json'"
