#!/usr/bin/env bash

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

# shellcheck source=scripts/lib/preview-names.sh
source "$REPO_ROOT/scripts/lib/preview-names.sh"

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [[ "$actual" == "$expected" ]]; then
        _record_pass "$msg"
    else
        _record_fail "$msg (expected '${expected}', got '${actual}')"
    fi
}

assert_le() {
    local actual="$1" max="$2" msg="$3"
    if (( actual <= max )); then
        _record_pass "$msg"
    else
        _record_fail "$msg (got ${actual}, max ${max})"
    fi
}

legacy_sanitise() {
    local s
    s="$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr '/_' '-' | cut -c1-30)"
    s="${s%-}"
    printf '%s' "$s"
}

test_case "bare_names_byte_identical" "PREVIEW_SUFFIX unset keeps historical names"
unset PREVIEW_SUFFIX
for branch in \
    "chore/enable-pipelines" \
    "Feature/Some_Long_Branch-Name-Exceeding-Thirty-Characters" \
    "fix/branch-that-cuts-on-a-dash-x" \
    "main"; do
    legacy="$(legacy_sanitise "$branch")"
    derive_preview_names "$branch"
    assert_eq "$PREVIEW_COMPONENT" "$legacy" "component == legacy sanitised ('${branch}')"
    assert_eq "$PREVIEW_CORE_APP" "stacks-core-pr-${legacy}" "core app unchanged ('${branch}')"
    assert_eq "$PREVIEW_SCRAPER_APP" "stacks-scraper-pr-${legacy}" "scraper app unchanged ('${branch}')"
    assert_eq "$PREVIEW_SEARXNG_APP" "stacks-searxng-pr-${legacy}" "searxng app unchanged ('${branch}')"
    assert_eq "$PREVIEW_MODAL_APP" "thestacks-vision-${legacy}" "modal app unchanged ('${branch}')"
    assert_eq "$PREVIEW_NEON_BRANCH" "preview/${legacy}" "neon branch unchanged ('${branch}')"
done

test_case "suffixed_names_differ" "PREVIEW_SUFFIX makes CI names disjoint from local names"
unset PREVIEW_SUFFIX
derive_preview_names "chore/enable-pipelines"
bare_core="$PREVIEW_CORE_APP"
bare_neon="$PREVIEW_NEON_BRANCH"

export PREVIEW_SUFFIX="ci423704"
derive_preview_names "chore/enable-pipelines"
if [[ "$PREVIEW_CORE_APP" != "$bare_core" ]]; then
    _record_pass "suffixed core app differs from bare (${PREVIEW_CORE_APP} vs ${bare_core})"
else
    _record_fail "suffixed core app identical to bare (${PREVIEW_CORE_APP})"
fi
if [[ "$PREVIEW_NEON_BRANCH" != "$bare_neon" ]]; then
    _record_pass "suffixed neon branch differs from bare (${PREVIEW_NEON_BRANCH} vs ${bare_neon})"
else
    _record_fail "suffixed neon branch identical to bare (${PREVIEW_NEON_BRANCH})"
fi
assert_contains "$PREVIEW_CORE_APP" "-ci423704" "core app carries the suffix"
assert_contains "$PREVIEW_SCRAPER_APP" "-ci423704" "scraper app carries the suffix"
assert_contains "$PREVIEW_SEARXNG_APP" "-ci423704" "searxng app carries the suffix"
assert_contains "$PREVIEW_MODAL_APP" "-ci423704" "modal app carries the suffix"
assert_contains "$PREVIEW_NEON_BRANCH" "-ci423704" "neon branch carries the suffix"

test_case "fly_app_name_cap" "all Fly app names <= 30 chars when suffixed"
export PREVIEW_SUFFIX="ci423704"
for branch in \
    "chore/enable-pipelines" \
    "Feature/Some_Long_Branch-Name-Exceeding-Thirty-Characters" \
    "a" \
    "fix/ab-cdefghij"; do
    derive_preview_names "$branch"
    assert_le "${#PREVIEW_CORE_APP}" 30 "core app <= 30 ('${branch}' → ${PREVIEW_CORE_APP})"
    assert_le "${#PREVIEW_SCRAPER_APP}" 30 "scraper app <= 30 ('${branch}' → ${PREVIEW_SCRAPER_APP})"
    assert_le "${#PREVIEW_SEARXNG_APP}" 30 "searxng app <= 30 ('${branch}' → ${PREVIEW_SEARXNG_APP})"
done

test_case "suffix_sanitisation" "uppercase / slash / underscore in suffix are normalised"
export PREVIEW_SUFFIX="CI/42_x"
derive_preview_names "main"
assert_contains "$PREVIEW_CORE_APP" "-ci-42-x" "suffix lowercased and / _ mapped to -"
assert_eq "$PREVIEW_COMPONENT" "main-ci-42-x" "component is '<branch>-<sanitised suffix>'"

test_case "no_dangling_hyphen" "branch truncation strips a trailing hyphen before joining"
export PREVIEW_SUFFIX="ci423704"
derive_preview_names "ab-cdef"
assert_eq "$PREVIEW_COMPONENT" "ab-ci423704" "component has no double hyphen"

test_case "oversized_suffix_fails" "suffix leaving no branch budget returns non-zero"
export PREVIEW_SUFFIX="ci12345678901"  # 13 chars > 10-char max
rc=0
out="$(derive_preview_names "main" 2>&1)" || rc=$?
assert_exit_nonzero "$rc" "derive_preview_names fails for a 13-char suffix"
assert_contains "$out" "FAIL preview-names" "failure message names the check"

unset PREVIEW_SUFFIX
summarise
