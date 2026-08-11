#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MARKER="vacuous-guard-check: allow"
violations=0

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
