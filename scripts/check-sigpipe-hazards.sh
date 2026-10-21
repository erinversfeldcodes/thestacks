#!/usr/bin/env bash
# Refuse a pipeline whose exit status is read but can be 141 instead of the
# answer.
#
# ⛔ WHY THIS GATE EXISTS — a security scan that reported "clean" on a critical
# finding. The shape:
#
#     if echo "$scan_out" | grep -q "[critical]"; then   # under set -o pipefail
#
# `grep -q` exits on its FIRST match and closes the pipe. `echo` is still
# writing, so it takes SIGPIPE and dies with 141. Under `pipefail` the
# PIPELINE's status is that 141, not grep's 0 — so the `if` goes FALSE **on a
# match** and the else branch runs. Measured on a 300KB payload: match first →
# rc=141, match last → rc=0.
#
# That size-dependence is what makes it so dangerous. It needs the payload to
# exceed the pipe buffer with the match inside it, so it is invisible on small
# inputs, intermittent near the boundary (it was first found as a 2-in-6 flake),
# and reliable only once the output is big — i.e. it arrives exactly when a
# scanner has the most to report. Auditing payload sizes is the wrong fix; the
# form is wrong at any size, and a here-string costs nothing.
#
# ⚠️ Scope: the first sweep for this looked only at `scripts/check-*.sh`, which
# is why the integration gate and the deploy gate kept the bug for another
# round. Completeness here is a fact about the hazard, not about a directory,
# so this gate reads every pipefail-bearing shell script in the repo.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# Consumers that may exit before the producer has finished writing. `head` and
# `grep -m<n>` always do; `grep -q` does on a match; `sed …q` and `awk …exit`
# do on their condition. The `-[a-zA-Z]*q` spelling is deliberate: `grep -Eq`
# and `grep -iq` are the same defect as `grep -qE`, and a pattern that only
# caught the one spelling already in the tree would miss the next one.
#
# ⚠️ The leading `[^|]` is load-bearing: without it this matches the `||` in
# `cmd_a || grep -q PAT file`, which has no pipe at all. Two such sites read as
# hazards in the first run of this gate, and a gate with false positives gets
# an exemption list bolted on — which is how the predecessor to this family of
# checks ended up with eight free-text reasons, seven of them untrue.
CONSUMER='[^|]\| *(grep [^|]*-[a-zA-Z]*q|grep [^|]*-m *[0-9]|head( |$)|sed -n [^|]*q|awk [^|]*exit)'

# A site only misbehaves if the pipeline's STATUS is consumed as a decision.
# `X="$(cmd | head -1)"` uses stdout and discards the status, so it is correct
# (under `set -e` it aborts loudly, which is a different and visible problem).
STATUS_IS_READ='^[[:space:]]*(if|elif|while|!)[[:space:]]|^[[:space:]]*(\|\||&&)|(\|\||&&)[[:space:]]*$'

FOUND=0
SCANNED=0
REPORT=""

while IFS= read -r file; do
    # Only scripts where pipefail is actually in effect.
    grep -qE '^[[:space:]]*set .*pipefail' "$file" || continue
    SCANNED=$((SCANNED + 1))

    # Strip comments before matching: this gate must not read the prose that
    # explains the banned form as an instance of it. Every fix in the tree
    # carries a comment quoting the bad shape, and an absence check that counts
    # those is the "gates read their own comments as configuration" defect.
    while IFS=: read -r lineno text; do
        [ -n "${lineno:-}" ] || continue
        grep -qE "$STATUS_IS_READ" <<< "$text" || continue
        FOUND=$((FOUND + 1))
        REPORT="${REPORT}  ${file}:${lineno}
    ${text}
"
    done < <(sed 's/#.*//' "$file" | grep -nE "$CONSUMER" || true)
    # ⛔ Tracked AND untracked-but-not-ignored, deduplicated. `git ls-files`
    # alone cannot see a new script, which is not hypothetical: this gate was
    # invisible to ITSELF until it was committed, and the run that first
    # included it found two violations in its own guidance text. A gate whose
    # corpus excludes the file being added is a gate that passes every new
    # script until someone happens to commit it.
done < <({ git ls-files '*.sh'; git ls-files --others --exclude-standard '*.sh'; } | sort -u)

# ⚠️ Anti-vacuity. If the discovery stops finding scripts — a renamed
# directory, a changed shebang convention, `git ls-files` run outside a repo —
# "0 hazards" is indistinguishable from "0 files read". The floor makes the
# difference visible, which is the failure mode this whole class keeps taking.
FLOOR=30
if [[ "${SCANNED}" -lt "${FLOOR}" ]]; then
    echo "FAIL check-sigpipe-hazards: only ${SCANNED} pipefail-bearing scripts discovered, floor is ${FLOOR}." >&2
    echo "  Either the discovery broke or the convention changed. A clean result from" >&2
    echo "  a broken search is the defect this gate exists to catch, so refusing." >&2
    exit 1
fi

# ⛔ The corpus is safe partly because of a fact outside it: every script here
# is bash-shebanged, and bash word-splits an unquoted parameter. Several gates
# rely on that — `for entry in $RLS_SCOPE_TEST_ALLOWLIST` and
# `for _stale in $_STALE_IDS` are both correct ONLY under a splitting shell.
#
# Under zsh an unquoted parameter is NOT split, so those loops would silently
# iterate once over the whole string: `git diff -- $paths` becomes one pathspec
# matching nothing, exits 0, and reports an empty result. That is this file's
# own failure mode — a work set that is empty for the wrong reason — and it is
# how a reviewer's five stale reviews got dispatched as four narrow ones.
#
# ⚠️ The fix for such a site is an ARRAY, not quoting: `"$paths"` reproduces
# the single-argument bug under bash too, which is the opposite of the
# glob-quoting convention this repo otherwise follows. Nothing in the corpus
# needs changing today; what needs guarding is the ambient assumption.
if grep -qE '^[[:space:]]*set[[:space:]]+shell[[:space:]]*:=' "$REPO_ROOT/justfile" 2>/dev/null; then
    if grep -qE '^[[:space:]]*set[[:space:]]+shell[[:space:]]*:=.*zsh' "$REPO_ROOT/justfile"; then
        echo "FAIL check-sigpipe-hazards: the justfile sets a zsh shell." >&2
        echo "  Several gates rely on an unquoted parameter being word-split, which zsh does" >&2
        echo "  not do — those loops would iterate once over the whole string and report an" >&2
        echo "  empty result rather than failing. Use bash, or convert every such site to an" >&2
        echo "  array (quoting is NOT the fix — it reproduces the bug under bash)." >&2
        exit 1
    fi
fi

if [[ "${FOUND}" -ne 0 ]]; then
    echo "FAIL check-sigpipe-hazards: ${FOUND} pipeline(s) whose status is read can return 141 instead of an answer." >&2
    printf '%s' "${REPORT}" >&2
    cat >&2 <<'GUIDE'

  Under `pipefail`, an early-exiting consumer kills the producer with SIGPIPE
  and the pipeline reports 141 — so the test goes the WRONG WAY on a match.

  Rewrite to drop the pipe. (Described rather than shown: this guidance is
  printed by the gate, not commented out, so spelling the banned form here
  literally would make the gate report itself -- which it did once.)

      a pipe from echo/printf into `grep -q PAT`
          -> drop the producer, feed grep a here-string: grep -q PAT <<< "$out"

      a pipe from any command into `grep -q PAT`
          -> capture first: out="$(cmd || true)", then the here-string form

      a pipe into `head -N` used for truncation
          -> capture, then slice: cmd_out="$(cmd)"; X="${cmd_out:0:2000}"

  If a site is genuinely safe, it still has to stop reading the status —
  `| grep -q … || true` is not a fix, it discards the answer.
GUIDE
    exit 1
fi

echo "OK: ${SCANNED} pipefail-bearing script(s), no pipeline into an early-exiting consumer whose status is read."
