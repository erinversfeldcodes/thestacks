#!/usr/bin/env bash
#
# Promotion / merge gate for the Writing Assistant eval.
#
# RED while the golden set + baseline are the dummy PLACEHOLDER that unblocks
# development; GREEN only once the owner's real golden set has been authored and
# a real baseline recorded (placeholder: false). This is deliberately NOT part
# of `just verify` / `just ci` — dev stays green on the dummy set — it is the
# gate run before merge to main, so the branch cannot ship the assistant on
# placeholder data. It pairs with the eval and training work staying unpromoted
# in the campaign state until the owner's real golden set is recorded.
#
# Usage: bash scripts/check-assistant-promoted.sh
set -euo pipefail

BASELINE="apps/core/priv/eval/assistant_baseline.json"
GOLDEN="apps/core/priv/eval/assistant_golden.exs"

if [[ ! -f "$BASELINE" ]]; then
  echo "FAIL: no assistant eval baseline at $BASELINE." >&2
  echo "  Record one with (cd apps/core && mix eval.assistant --record)." >&2
  exit 1
fi

if grep -qE '"placeholder"[[:space:]]*:[[:space:]]*true' "$BASELINE"; then
  echo "BLOCKED: the Writing Assistant eval baseline is still the dummy PLACEHOLDER." >&2
  echo "  Before merge to main:" >&2
  echo "    1. author the real golden set in $GOLDEN (owner-written dialogues)," >&2
  echo "    2. run the real training + eval on a deployment," >&2
  echo "    3. set placeholder: false and (cd apps/core && mix eval.assistant --record)." >&2
  exit 1
fi

echo "OK: the Writing Assistant eval baseline is promoted (not placeholder)."
