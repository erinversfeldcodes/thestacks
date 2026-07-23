#!/usr/bin/env bash
set -euo pipefail

# Guard against reintroducing "vacuous" E2E assertion guards (Issue #275).
#
# A guard of the shape
#     if ((await LOCATOR.count()) > 0) { ...assertions... }
#     test.skip((await LOCATOR.count()) === 0, ...)
# makes the wrapped assertion pass whenever the element is ABSENT — the test can
# never fail, and a regression that removes the element entirely reports green.
# Worse, it can conceal a wrong selector (a test that was never correct).
#
# A genuinely-conditional either/or (e.g. mutually-exclusive terminal states
# where EVERY branch still asserts something) is allowed, but must be opted out
# explicitly with a marker comment on the guard line or the line directly above:
#     // vacuous-guard-check: allow — <reason it is legitimately optional>
#
# See docs/agents/standards/testing.md ("Vacuous assertion guards").

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MARKER="vacuous-guard-check: allow"
violations=0

while IFS= read -r file; do
  # awk flags the vacuous idiom unless the line — or the line directly above —
  # carries the allow marker. Prints "file:line: <offending source>".
  if ! awk -v marker="$MARKER" -v fname="$file" '
    {
      line = $0
      # Skip comment lines — prose may legitimately quote a banned idiom (e.g. a
      # doc-comment explaining what was removed). Guard code never starts with a
      # comment marker.
      trimmed = line
      sub(/^[[:space:]]+/, "", trimmed)
      if (trimmed ~ /^(\/\/|\*|\/\*)/) { prev = $0; next }
      is_guard = 0
      if (line ~ /if[[:space:]]*\(\(await[^;]*\.count\(\)\)[[:space:]]*>[[:space:]]*0\)/) is_guard = 1
      if (line ~ /test\.skip\(\(await[^;]*\.count\(\)\)[[:space:]]*===[[:space:]]*0/) is_guard = 1
      # Fail-open skip on a 5xx server error (e.g. test.skip(status === 502, …)) —
      # a server-error tolerance that makes the test unable to fail (Issue #275 /
      # #166). Assert the real expectation, or honour the documented retry contract.
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

✗ Vacuous assertion guard(s) found in E2E specs (Issue #275).

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

echo "✓ No vacuous E2E assertion guards (Issue #275)."
