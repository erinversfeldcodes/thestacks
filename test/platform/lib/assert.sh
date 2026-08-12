#!/usr/bin/env bash

set -u

TESTS_PASSED=0
TESTS_FAILED=0
FAILED_MSGS=()
CURRENT_CASE=""

test_case() {
    CURRENT_CASE="$1"
    printf '\n# === %s ===\n' "$1"
    if [[ -n "${2:-}" ]]; then
        printf '# %s\n' "$2"
    fi
}

_record_pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf 'ok   %s — %s\n' "$CURRENT_CASE" "$1"
}

_record_fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_MSGS+=("${CURRENT_CASE}: $1")
    printf 'FAIL %s — %s\n' "$CURRENT_CASE" "$1"
}

assert_exit_zero() {
    local actual="$1"
    local msg="${2:-exit code is zero}"
    if [[ "$actual" -eq 0 ]]; then
        _record_pass "$msg"
    else
        _record_fail "$msg (got exit $actual)"
    fi
}

assert_exit_nonzero() {
    local actual="$1"
    local msg="${2:-exit code is nonzero}"
    if [[ "$actual" -ne 0 ]]; then
        _record_pass "$msg"
    else
        _record_fail "$msg (got exit 0)"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-output contains: $needle}"
    if [[ "$haystack" == *"$needle"* ]]; then
        _record_pass "$msg"
    else
        _record_fail "$msg (output: $(printf '%s' "$haystack" | head -c 400))"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-output does not contain: $needle}"
    if [[ "$haystack" != *"$needle"* ]]; then
        _record_pass "$msg"
    else
        _record_fail "$msg"
    fi
}

assert_path_exists() {
    local path="$1"
    local msg="${2:-path exists: $path}"
    if [[ -e "$path" ]]; then
        _record_pass "$msg"
    else
        _record_fail "$msg (file not found: $path)"
    fi
}

summarise() {
    printf '\n# ——————————————————————————\n'
    printf '# passed: %d  failed: %d\n' "$TESTS_PASSED" "$TESTS_FAILED"
    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        printf '# failures:\n'
        for m in "${FAILED_MSGS[@]}"; do
            printf '#   - %s\n' "$m"
        done
        return 1
    fi
    return 0
}
