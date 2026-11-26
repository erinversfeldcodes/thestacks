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

# The longest leading chunk of the needle that appears anywhere, with the lines
# it appears on. This is the part that actually helps: "you searched for
# `11 4 * * *` and the file says `11 4 * * 0`" locates the problem, whereas the
# first 400 bytes of a file locates its header.
_near_misses() {
    local haystack="$1" needle="$2"
    local len=${#needle}
    local step=$(( len / 8 + 1 ))
    local n=$len
    local prefix hits

    while [[ $n -ge 4 ]]; do
        prefix="${needle:0:$n}"
        hits="$(printf '%s\n' "$haystack" | grep -nF -- "$prefix" 2>/dev/null | head -3)"
        if [[ -n "$hits" ]]; then
            printf 'nearest — lines matching the first %d of %d chars ("%s"):\n%s' \
                "$n" "$len" "$prefix" "$hits"
            return 0
        fi
        n=$(( n - step ))
    done
    return 1
}

# ⚠️ On failure this used to print the first 400 bytes of the haystack, which is
# the right thing for command output and actively misleading for a whole file —
# `idor_gate_test.sh` was the first caller to hand it one and got the YAML
# header back, telling the reader nothing. That suite worked around it by
# scoping its haystack to a single step; the shared library stayed as it was,
# and the next two suites to grep whole files hit the same wall.
#
# So the output now depends on what it was given: a small haystack is shown in
# full, and a large one reports its size and the nearest near-miss rather than
# an arbitrary prefix.
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-output contains: $needle}"

    if [[ "$haystack" == *"$needle"* ]]; then
        _record_pass "$msg"
        return
    fi

    local bytes lines detail near
    bytes="$(printf '%s' "$haystack" | wc -c | tr -d ' ')"
    lines="$(printf '%s\n' "$haystack" | wc -l | tr -d ' ')"

    if [[ "$bytes" -le 400 ]]; then
        detail="output: $haystack"
    else
        detail="haystack is ${bytes} bytes / ${lines} lines, not shown in full"
        if near="$(_near_misses "$haystack" "$needle")"; then
            detail="${detail}
    ${near}"
        else
            detail="${detail}
    nearest — no part of the needle appears at all"
        fi
    fi

    _record_fail "$msg (${detail})"
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
