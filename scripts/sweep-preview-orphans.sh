#!/usr/bin/env bash
# scripts/sweep-preview-orphans.sh — destroy preview resources no open PR owns.
#
# The backstop for previews cleanup-preview.sh never ran against: manual
# deploys, crashed CI runs, closed PRs from before the close-trigger existed.
# A leaked preview stack once ran 24/7 for three days after its branch merged;
# this sweep exists so that class of leak has a bounded lifetime.
#
# Orphan = a Fly app matching a preview name pattern (or a Neon branch under
# preview/) that does NOT belong to any OPEN pull request's derived names AND
# is older than the grace period (protects in-flight CI runs, whose
# ci-suffixed names are never in the open-PR set).
#
# Fails loudly if any listing step fails — a sweep that silently sweeps
# nothing is how the last leak survived (see the pre-rollback cleanup's
# .creation_time lesson).
#
# Required env vars:
#   FLY_API_TOKEN — Fly.io API token
#   GH_TOKEN      — GitHub token able to list the repo's open PRs
#
# Optional env vars:
#   NEON_STAGING_API_KEY / NEON_STAGING_PROJECT_ID — enables the Neon sweep
#   GRACE_HOURS  — minimum resource age before it is sweepable (default 24)
#   GH_REPO      — owner/repo to list PRs from (default: derived by gh)
#
# Usage:
#   scripts/sweep-preview-orphans.sh --dry-run   # print what would go
#   scripts/sweep-preview-orphans.sh             # destroy orphans

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

GRACE_HOURS="${GRACE_HOURS:-24}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/preview-names.sh
source "${REPO_ROOT}/scripts/lib/preview-names.sh"

command -v fly >/dev/null || { echo "FAIL sweep: flyctl not on PATH" >&2; exit 1; }
command -v gh >/dev/null || { echo "FAIL sweep: gh not on PATH" >&2; exit 1; }
[[ -n "${FLY_API_TOKEN:-}" ]] || { echo "FAIL sweep: FLY_API_TOKEN not set" >&2; exit 1; }

# ── Allowlist: every name an OPEN PR's branch derives (suffix-less) ─────────
open_branches="$(gh pr list ${GH_REPO:+--repo "$GH_REPO"} --state open --limit 200 \
    --json headRefName --jq '.[].headRefName')" \
    || { echo "FAIL sweep: could not list open PRs" >&2; exit 1; }

ALLOW_FILE="$(mktemp)"
trap 'rm -f "$ALLOW_FILE"' EXIT
while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    PREVIEW_SUFFIX="" derive_preview_names "$branch"
    printf '%s\n' \
        "$PREVIEW_CORE_APP" "$PREVIEW_SCRAPER_APP" "$PREVIEW_SEARXNG_APP" \
        "$PREVIEW_VM_APP" "$PREVIEW_GRAFANA_APP" "$PREVIEW_NEON_BRANCH" \
        >> "$ALLOW_FILE"
done <<< "$open_branches"

allowed() { grep -qxF "$1" "$ALLOW_FILE"; }

now_epoch="$(date -u +%s)"
grace_seconds=$(( GRACE_HOURS * 3600 ))

# Age of a Fly app = age of its NEWEST machine (a redeploy refreshes it).
# An app with no machines at all is an empty husk and always sweepable.
app_age_ok() {
    local app="$1" newest
    newest="$(fly machines list --app "$app" --json 2>/dev/null \
        | python3 -c "
import json, sys, datetime
try:
    machines = json.load(sys.stdin)
except Exception:
    machines = []
if not machines:
    print(0)
else:
    ts = max(m['created_at'] for m in machines)
    ts = ts.split('.')[0].rstrip('Z')
    dt = datetime.datetime.fromisoformat(ts).replace(tzinfo=datetime.timezone.utc)
    print(int(dt.timestamp()))
")" || return 1
    [[ "$newest" == "0" ]] && return 0
    (( now_epoch - newest >= grace_seconds ))
}

echo "==> Sweeping preview orphans (grace: ${GRACE_HOURS}h, dry-run: ${DRY_RUN})"
echo "    Open-PR allowlist entries: $(wc -l < "$ALLOW_FILE" | tr -d ' ')"

# ── Fly apps ────────────────────────────────────────────────────────────────
apps="$(fly apps list --json | python3 -c "
import json, sys, re
pattern = re.compile(r'^stacks-(core|scraper|searxng|vm|grafana)-pr-')
for a in json.load(sys.stdin):
    if pattern.match(a['Name'] if 'Name' in a else a.get('name', '')):
        print(a.get('Name') or a.get('name'))
")" || { echo "FAIL sweep: could not list Fly apps" >&2; exit 1; }

swept=0 kept=0
while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    if allowed "$app"; then
        echo "    KEEP ${app} (open PR)"
        kept=$(( kept + 1 ))
        continue
    fi
    if ! app_age_ok "$app"; then
        echo "    KEEP ${app} (younger than ${GRACE_HOURS}h — possibly in-flight CI)"
        kept=$(( kept + 1 ))
        continue
    fi
    if (( DRY_RUN )); then
        echo "    WOULD DESTROY ${app}"
    else
        fly apps destroy "$app" --yes 2>/dev/null \
            && echo "    DESTROYED ${app}" \
            || echo "    WARN: failed to destroy ${app}" >&2
    fi
    swept=$(( swept + 1 ))
done <<< "$apps"

# ── Neon preview branches (staging project) ─────────────────────────────────
if [[ -n "${NEON_STAGING_API_KEY:-}" && -n "${NEON_STAGING_PROJECT_ID:-}" ]]; then
    branches_json="$(curl -sfL \
        -H "Authorization: Bearer ${NEON_STAGING_API_KEY}" \
        "https://console.neon.tech/api/v2/projects/${NEON_STAGING_PROJECT_ID}/branches")" \
        || { echo "FAIL sweep: could not list Neon branches" >&2; exit 1; }

    while IFS=$'\t' read -r bid bname bcreated; do
        [[ -z "$bid" || "$bname" != preview/* ]] && continue
        if allowed "$bname"; then
            echo "    KEEP neon:${bname} (open PR)"
            continue
        fi
        created_epoch="$(python3 -c "
import datetime
ts = '${bcreated}'.split('.')[0].rstrip('Z')
print(int(datetime.datetime.fromisoformat(ts).replace(tzinfo=datetime.timezone.utc).timestamp()))
")"
        if (( now_epoch - created_epoch < grace_seconds )); then
            echo "    KEEP neon:${bname} (younger than ${GRACE_HOURS}h)"
            continue
        fi
        if (( DRY_RUN )); then
            echo "    WOULD DELETE neon branch ${bname}"
        else
            curl -sf -X DELETE \
                -H "Authorization: Bearer ${NEON_STAGING_API_KEY}" \
                "https://console.neon.tech/api/v2/projects/${NEON_STAGING_PROJECT_ID}/branches/${bid}" \
                >/dev/null \
                && echo "    DELETED neon branch ${bname}" \
                || echo "    WARN: failed to delete neon branch ${bname}" >&2
        fi
        swept=$(( swept + 1 ))
    done < <(printf '%s' "$branches_json" | python3 -c "
import json, sys
for b in json.load(sys.stdin).get('branches', []):
    print(f\"{b['id']}\t{b['name']}\t{b['created_at']}\")
")
else
    echo "    SKIP: NEON_STAGING_API_KEY/NEON_STAGING_PROJECT_ID not set — Fly-only sweep."
fi

echo ""
echo "Sweep complete: ${swept} orphan(s) $( (( DRY_RUN )) && echo 'found' || echo 'removed'), ${kept} kept."
