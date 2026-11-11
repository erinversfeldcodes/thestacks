#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MARKER="vacuous-guard-check: allow"
violations=0

# ⚠️ ANTI-VACUITY — defence in depth, not a fix for an observed failure, and
# the distinction is worth being honest about since this file is about exactly
# that kind of overclaim.
#
# What is TRUE: the spec list is fed in below through a process substitution,
# and a process substitution's exit status cannot reach `set -e`. If `find`
# fails — `e2e/tests` renamed or removed — it writes to stderr, yields nothing,
# the loop body never executes, `violations` stays 0, and this script would
# print a pass having read no files. For a gate whose entire subject is
# assertions that pass because their target is absent, that is the one failure
# mode it must not have.
#
# What is NOT true, and was claimed here in an earlier draft of this comment:
# that this had been observed. It had not. `REPO_ROOT` here is derived from
# `BASH_SOURCE`, so this script always `cd`s into the real repository and the
# vacuity probe that caught `check-component-dispatch.sh` (shadow `git` so
# `REPO_ROOT` falls back to `.`) never reached this file at all. Its exit 0
# under that probe was a correct pass over the real 56 specs.
#
# The guard stays because the `find` failure path is real and cheap to close,
# and the count now appears in the success message so a future reader can see
# what was actually read.
SPEC_COUNT="$(find e2e/tests -name '*.spec.ts' -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "${SPEC_COUNT:-0}" -lt 1 ]; then
  cat >&2 <<'EOF'
✗ Found no Playwright specs under e2e/tests.

  This gate reads every `*.spec.ts` there; zero means the tree is not where it
  looks, not that the suite has no vacuous guards. Reporting a pass here would
  be the very defect this gate exists to catch, one level up.
EOF
  exit 1
fi

while IFS= read -r file; do
  if ! awk -v marker="$MARKER" -v fname="$file" '
    {
      line = $0
      trimmed = line
      sub(/^[[:space:]]+/, "", trimmed)
      if (trimmed ~ /^(\/\/|\*|\/\*)/) { prev = $0; next }
      is_guard = 0
      if (line ~ /if[[:space:]]*\(\(await[^;]*\.count\(\)\)[[:space:]]*>[[:space:]]*0\)/) is_guard = 1
      if (line ~ /test\.skip\(\(await[^;]*\.count\(\)\)[[:space:]]*===[[:space:]]*0/) is_guard = 1
      if (line ~ /test\.skip\([^,]*status[^,]*(50[0-9])/) is_guard = 1
      if (is_guard) {
        allowed = (index(line, marker) > 0) || (index(prev, marker) > 0)
        if (!allowed) {
          sub(/^[[:space:]]+/, "", line)
          printf "%s:%d: %s\n", fname, NR, line
          bad++
        }
      }
      prev = $0
    }
    END { exit (bad > 0 ? 1 : 0) }
  ' "$file"; then
    violations=1
  fi
done < <(find e2e/tests -name '*.spec.ts' -type f | sort)

if [ "$violations" -ne 0 ]; then
  cat >&2 <<'EOF'

✗ Vacuous assertion guard(s) found in E2E specs.

  An `if ((await …count()) > 0)` block or `test.skip((await …count()) === 0)`
  passes when its target is ABSENT, so the wrapped assertion can never fail.

  Fix one of these ways:
    • Vestigial guard → delete it and assert unconditionally (make the data
      deterministic with a seed/setup helper if the element is not always there).
    • Genuine either/or where every branch still asserts → keep it, but add a
      marker comment on the guard line or the line directly above it:
          // vacuous-guard-check: allow — <why it is legitimately optional>

  See docs/agents/standards/testing.md ("Vacuous assertion guards").
EOF
  exit 1
fi

echo "✓ No vacuous E2E assertion guards across ${SPEC_COUNT} spec file(s)."
