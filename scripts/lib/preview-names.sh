#!/usr/bin/env bash
# scripts/lib/preview-names.sh — single source of truth for preview resource
# name derivation.
#
# Sourced by deploy-stack.sh, deploy-preview.sh, cleanup-preview.sh, ci.sh,
# and the deploy-preview job in .github/workflows/ci.yml. Testable standalone
# via test/platform/preview_names_test.sh.
#
# Why this exists (Issue #170 C): local `just ci` and GitHub Actions used to
# derive IDENTICAL preview names from the branch, so a local run's cleanup
# could delete the Neon branch out from under a concurrent CI run (observed
# 2026-07-07: CI's IDOR step 5xx'd against a deleted Neon endpoint). CI now
# sets PREVIEW_SUFFIX (unique per workflow run) so its resources never
# collide with local runs. Local runs leave PREVIEW_SUFFIX unset and keep
# the historical bare names — byte-identical to the pre-#170 derivation.
#
# Usage:
#   source "${REPO_ROOT}/scripts/lib/preview-names.sh"
#   derive_preview_names "my/branch_name"
#
# Reads (optional):
#   PREVIEW_SUFFIX — extra uniqueness component, e.g. "ci123456" in GitHub
#                    Actions (ci.yml derives it as "ci" + last 6 digits of
#                    github.run_id). Sanitised the same way as the branch.
#
# Sets (globals):
#   PREVIEW_COMPONENT   — sanitised "<branch>" or "<branch>-<suffix>"
#   PREVIEW_CORE_APP    — stacks-core-pr-<component>      (Fly)
#   PREVIEW_SCRAPER_APP — stacks-scraper-pr-<component>   (Fly)
#   PREVIEW_SEARXNG_APP — stacks-searxng-pr-<component>   (Fly)
#   PREVIEW_MODAL_APP   — thestacks-vision-<component>    (Modal)
#   PREVIEW_NEON_BRANCH — preview/<component>             (Neon)
#
# Length budget: Fly app names are capped at 30 characters. The longest
# per-preview Fly prefix is "stacks-scraper-pr-" / "stacks-searxng-pr-"
# (18 chars), leaving 12 chars for the shared component when a suffix is
# in play. The BRANCH part is truncated to fit — never the suffix, because
# the suffix is the uniqueness guarantee. All resources share one component
# so cleanup can re-derive every name from (branch, PREVIEW_SUFFIX) alone.
#
# Without PREVIEW_SUFFIX the historical derivation is preserved exactly
# (lowercase, / and _ → -, cut to 30 chars, strip one trailing hyphen) —
# existing preview apps keep their names.

# Lowercase and map / _ to -, matching the historical inline derivation.
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
        # 30 (Fly cap) - 18 (longest Fly prefix) = 12 chars for the whole
        # "<branch>-<suffix>" component.
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
