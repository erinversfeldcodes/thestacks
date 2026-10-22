#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v buf &>/dev/null; then
    echo "ERROR: 'buf' is not installed. Install it to lint proto schemas." >&2
    echo "  macOS: brew install bufbuild/buf/buf" >&2
    exit 1
fi

# `find … -quit | grep -q .` is safe only because `-quit` makes find exit after
# the first path, so it is never still writing when grep leaves. That is a
# property of the flags rather than of the form, and the next edit to this line
# will not know it — so capture instead, and the safety stops depending on a
# reader noticing `-quit`.
_first_proto="$(find "$REPO_ROOT/proto" -name "*.proto" -print -quit 2>/dev/null || true)"
if [[ -z "$_first_proto" ]]; then
    echo "No .proto files found in proto/ — skipping."
    exit 0
fi

(cd "$REPO_ROOT/proto" && buf lint)

if [[ "${BUF_BREAKING_SKIP:-}" == "1" ]]; then
    echo "BUF_BREAKING_SKIP=1 — skipping buf breaking check (intentional migration)."
elif git rev-parse --verify origin/main &>/dev/null 2>&1; then
    # Captured first: `git ls-tree | grep -q` returns 141 under `pipefail` once
    # the tree listing is bigger than the pipe buffer and a .proto path matches
    # before git finishes writing. That would take the else branch and SKIP
    # `buf breaking` — losing contract protection without saying so.
    _main_tree="$(git ls-tree -r origin/main --name-only 2>/dev/null || true)"
    if grep -q '\.proto$' <<< "${_main_tree}"; then
        (cd "$REPO_ROOT/proto" && buf breaking --against '../.git#branch=origin/main,subdir=proto')
    else
        echo "No .proto files on origin/main — skipping buf breaking check."
    fi

    # A suppression that suppresses nothing is a standing allowance for its
    # whole file. Run straight after the check it polices, so the two cannot
    # drift apart.
    bash "$REPO_ROOT/scripts/check-breaking-suppressions-are-spent.sh"
else
    # ⛔ THIS BRANCH USED NOT TO EXIST, and its absence meant `buf breaking` had
    # NEVER RUN IN CI.
    #
    # The `lint-proto` job checks out with the default `fetch-depth`, so it gets
    # a shallow clone with no `origin/main` ref. `git rev-parse --verify
    # origin/main` then fails, the `elif` is false, and with no `else` the whole
    # construct fell through in silence — no check, no skip notice, lane green.
    # This repo's own Elixir lane states the rule being broken: "Nothing in here
    # may print SKIP. A gate that cannot run is a failure."
    #
    # Failing loudly rather than skipping, because the alternative is what was
    # already happening.
    echo "FAIL lint-proto: origin/main is not available, so buf breaking cannot run." >&2
    echo "       The contract gate compares against the default branch; without that ref" >&2
    echo "       there is nothing to compare and NOTHING WAS CHECKED." >&2
    echo "" >&2
    echo "       In CI: give the job 'fetch-depth: 0', or fetch the branch explicitly." >&2
    echo "       Locally: git fetch origin main" >&2
    echo "       Deliberately migrating the contract? BUF_BREAKING_SKIP=1 says so out loud." >&2
    exit 1
fi

python3 "$REPO_ROOT/scripts/check-enum-coverage.py"

if [[ "${CI:-}" != "true" ]]; then
    if [[ -x "$REPO_ROOT/scripts/gen-elm-proto.sh" ]]; then
        bash "$REPO_ROOT/scripts/gen-elm-proto.sh" --check
    fi
    bash "$REPO_ROOT/scripts/gen-python-proto.sh" --check
    bash "$REPO_ROOT/scripts/gen-rust-proto.sh" --check
    bash "$REPO_ROOT/scripts/gen-elixir-proto.sh" --check
fi
