#!/usr/bin/env bash

_preview_sanitise() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '/_' '-'
}

derive_preview_names() {
    local branch="$1"
    local sanitised
    sanitised="$(_preview_sanitise "$branch" | cut -c1-30)"
    sanitised="${sanitised%-}"

    if [[ -n "${PREVIEW_SUFFIX:-}" ]]; then
        local suffix budget branch_budget branch_part
        suffix="$(_preview_sanitise "$PREVIEW_SUFFIX")"
        budget=12
        branch_budget=$(( budget - ${#suffix} - 1 ))
        if (( branch_budget < 1 )); then
            echo "FAIL preview-names: PREVIEW_SUFFIX '${suffix}' is too long — max $(( budget - 2 )) chars after sanitisation" >&2
            return 1
        fi
        branch_part="$(printf '%s' "$sanitised" | cut -c1-"$branch_budget")"
        branch_part="${branch_part%-}"
        PREVIEW_COMPONENT="${branch_part}-${suffix}"
    else
        PREVIEW_COMPONENT="$sanitised"
    fi

    # shellcheck disable=SC2034  # globals consumed by the sourcing script
    PREVIEW_CORE_APP="stacks-core-pr-${PREVIEW_COMPONENT}"
    # shellcheck disable=SC2034
    PREVIEW_SCRAPER_APP="stacks-scraper-pr-${PREVIEW_COMPONENT}"
    # shellcheck disable=SC2034
    PREVIEW_SEARXNG_APP="stacks-searxng-pr-${PREVIEW_COMPONENT}"
    # shellcheck disable=SC2034
    # Short prefix (13 chars) — "stacks-victoriametrics-pr-" (26) would blow the
    # 30-char Fly cap, so the metrics-store preview app uses `stacks-vm-pr-`.
    PREVIEW_VM_APP="stacks-vm-pr-${PREVIEW_COMPONENT}"
    # shellcheck disable=SC2034
    # "stacks-grafana-pr-" is 18 chars — same as the scraper/searxng prefixes the
    # 12-char component budget is sized for, so it fits the 30-char Fly cap.
    PREVIEW_GRAFANA_APP="stacks-grafana-pr-${PREVIEW_COMPONENT}"
    # shellcheck disable=SC2034
    PREVIEW_MODAL_APP="thestacks-vision-${PREVIEW_COMPONENT}"
    # shellcheck disable=SC2034
    PREVIEW_NEON_BRANCH="preview/${PREVIEW_COMPONENT}"
}
