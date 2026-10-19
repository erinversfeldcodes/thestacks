#!/usr/bin/env bash
# scripts/sweep-preview-orphans.sh — destroy preview resources no open PR owns.
#
# The backstop for previews cleanup-preview.sh never ran against: manual
# deploys, crashed CI runs, closed PRs from before the close-trigger existed.
# A leaked preview stack once ran 24/7 for three days after its branch merged;
# this sweep exists so that class of leak has a bounded lifetime.
#
# Orphan = a Fly app matching a preview name pattern, a Neon branch under
# preview/, or a deployed Modal app named thestacks-vision-* that does NOT
# belong to any OPEN pull request's derived names AND is older than the grace
# period (protects in-flight CI runs, whose ci-suffixed names are never in the
# open-PR set).
#
# ⛔ A preview deploy creates THREE kinds of resource and this sweep covered two
# of them. Measured 2026-10-19: 26 Modal apps existed and 24 were orphans, the
# oldest from 20 July — found by hand, because nothing would ever have collected
# them. The per-PR teardown's own Modal leg had been failing open for months
# (fixed separately); even with that fixed, a preview whose PR was never opened
# has only this sweep. So if a preview ever creates a fourth kind of resource,
# it owes this script a leg.
#
# ⚠️ What the open-PR allowlist does NOT protect, for every leg equally: a
# preview deployed from a branch with no PR open. That is deliberate — "no open
# PR owns this" is the whole definition of orphan here — and the grace period is
# the only cover. Deploy a preview you intend to keep from a branch with a PR.
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

# ⛔ A REFUSAL, not a skip, and the reason is this script's own history. The
# per-PR Modal teardown swallowed a missing CLI as "already gone" and reported
# success on every run for months. A sweep that cannot see Modal must say so and
# stop, because the alternative is a green weekly run that collected nothing.
#
# Prefer a `modal` on PATH (what CI installs) and fall back to the module form
# this repo's other scripts use inside the nix shell.
if command -v modal >/dev/null 2>&1; then
    MODAL=(modal)
elif python3 -m modal --version >/dev/null 2>&1; then
    MODAL=(python3 -m modal)
else
    echo "FAIL sweep: the modal CLI is not available — neither 'modal' on PATH nor" >&2
    echo "       'python3 -m modal'. A preview deploy creates a Modal vision app and this" >&2
    echo "       sweep is the only thing that collects one whose PR was never opened, so" >&2
    echo "       running without it would report success having swept nothing." >&2
    echo "       Install it (pip install modal) and re-run." >&2
    exit 1
fi

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
        "$PREVIEW_MODAL_APP" \
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

# ⚠️ Components whose Fly core app this run decided to KEEP. The Modal leg reads
# it, and that is what makes a preview's three resources behave as one stack.
#
# Modal reports no last-deploy time, only creation, so a long-lived branch's
# vision app looks ancient however recently it was redeployed — while its Fly
# apps are correctly protected by their newest machine. Without this the sweep
# would stop the vision half of a stack it had just decided was live, which
# breaks the upload loop on a preview somebody is using.
LIVE_FILE="$(mktemp)"
trap 'rm -f "$ALLOW_FILE" "$LIVE_FILE"' EXIT

note_live_component() {
    local app="$1"
    [[ "$app" == stacks-core-pr-* ]] || return 0
    printf '%s\n' "${app#stacks-core-pr-}" >> "$LIVE_FILE"
}

swept=0 kept=0
while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    if allowed "$app"; then
        echo "    KEEP ${app} (open PR)"
        note_live_component "$app"
        kept=$(( kept + 1 ))
        continue
    fi
    if ! app_age_ok "$app"; then
        echo "    KEEP ${app} (younger than ${GRACE_HOURS}h — possibly in-flight CI)"
        note_live_component "$app"
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
    echo "    SKIP: NEON_STAGING_API_KEY/NEON_STAGING_PROJECT_ID not set — no Neon sweep."
fi

# ── Modal vision apps ───────────────────────────────────────────────────────
#
# ⚠️ JSON, never the default table. `modal app list` renders a box-drawing table
# whose column positions are a presentation detail; a parse of that breaks
# silently and leaves the set difference empty, which reads as "nothing to do" —
# the same shape as the failure that let 24 orphans accumulate.
modal_json="$("${MODAL[@]}" app list --json 2>/dev/null)" \
    || { echo "FAIL sweep: could not list Modal apps" >&2; exit 1; }

# `Created at`, because Modal reports no last-deploy time. An app redeployed
# today still carries its original creation date, so creation age is a weaker
# signal than the Fly leg's newest-machine age — it protects a freshly created
# preview and not a long-lived one. The open-PR allowlist is what protects those.
#
# Stopped apps are already in their terminal state and are not listed as
# deployed; `app stop` is the whole action available here, there being no delete.
modal_rows="$(printf '%s' "$modal_json" | python3 -c "
import datetime, json, sys

for app in json.load(sys.stdin):
    name = app.get('Description') or ''
    state = (app.get('State') or '').lower()
    created = app.get('Created at') or ''
    try:
        epoch = int(datetime.datetime.fromisoformat(created).timestamp())
    except ValueError:
        # An unparseable date is NOT treated as old. Guessing here would stop a
        # live app on the strength of a format change.
        epoch = 0
    print(f'{name}\t{state}\t{epoch}')
")" || { echo "FAIL sweep: could not parse the Modal app listing" >&2; exit 1; }

modal_examined=0
while IFS=$'\t' read -r mname mstate mepoch; do
    [[ -z "$mname" ]] && continue
    modal_examined=$(( modal_examined + 1 ))

    # The production app is `thestacks-vision` exactly; a preview carries the
    # branch component after it. Matching the bare name would stop production.
    [[ "$mname" == thestacks-vision-* ]] || continue
    [[ "$mstate" == "deployed" ]] || continue

    if allowed "$mname"; then
        echo "    KEEP modal:${mname} (open PR)"
        kept=$(( kept + 1 ))
        continue
    fi
    if grep -qxF "${mname#thestacks-vision-}" "$LIVE_FILE" 2>/dev/null; then
        echo "    KEEP modal:${mname} (its Fly stack is live)"
        kept=$(( kept + 1 ))
        continue
    fi
    if [[ "$mepoch" == "0" ]] || (( now_epoch - mepoch < grace_seconds )); then
        echo "    KEEP modal:${mname} (younger than ${GRACE_HOURS}h, or undated)"
        kept=$(( kept + 1 ))
        continue
    fi
    if (( DRY_RUN )); then
        echo "    WOULD STOP modal:${mname}"
    else
        "${MODAL[@]}" app stop "$mname" >/dev/null 2>&1 \
            && echo "    STOPPED modal:${mname}" \
            || echo "    WARN: failed to stop modal app ${mname}" >&2
    fi
    swept=$(( swept + 1 ))
done <<< "$modal_rows"

# ⛔ ANTI-VACUITY. Every verdict above is a set difference, which is empty when
# everything is tidy AND when nothing was listed. The account holds the
# production app at minimum, so examining zero apps means the listing or the
# parse returned nothing and the Modal leg just reported a clean sweep over an
# empty set.
if (( modal_examined == 0 )); then
    echo "FAIL sweep: examined 0 Modal apps. The production app alone guarantees at least" >&2
    echo "       one, so this is a broken listing or parse reporting itself as tidy." >&2
    exit 1
fi
echo "    Modal apps examined: ${modal_examined}"

echo ""
echo "Sweep complete: ${swept} orphan(s) $( (( DRY_RUN )) && echo 'found' || echo 'removed'), ${kept} kept."
