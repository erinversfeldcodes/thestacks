#!/usr/bin/env bash
# Holds: object-storage backend selection is a DELIBERATE declaration, never
# inferred from whether a credential happens to be present.
#
# ⛔ WHY THIS GATE EXISTS. `config/runtime.exs` selected R2 with
# `if r2_account_id = System.get_env("R2_ACCOUNT_ID")` for seven months. Two
# measured consequences, neither of which any gate reported:
#
#   - every developer machine with credentials in `.env` read, wrote and
#     DELETED objects in the shared bucket (13 of 25 sampled keys had rows in
#     the production database);
#   - a deployed stack WITHOUT those secrets fell back to Stacks.Storage.Local,
#     writing reader photos to a container filesystem with no volume, on a
#     machine that stops when idle.
#
# A config file is the one place where "it looked right" is the only check
# available, which is why the decision now lives in a tested module and why
# this gate holds it there.
set -uo pipefail
cd "$(dirname "$0")/.."

RUNTIME="config/runtime.exs"
SELECTION="apps/core/lib/stacks/storage/selection.ex"
SELECTION_TEST="apps/core/test/stacks/storage/selection_test.exs"

fail() { echo "FAIL: $1" >&2; exit 1; }

for f in "$RUNTIME" "$SELECTION" "$SELECTION_TEST"; do
  [ -f "$f" ] || fail "$f is missing — the selection decision has moved without this gate moving with it."
done

# ⚠️ Comments are stripped for the ABSENCE checks only. This repo has been
# burned by a gate matching the prose that explains why a pattern is banned —
# and the explanations above are exactly that prose.
runtime_code=$(sed 's/#.*//' "$RUNTIME")
selection_code=$(sed 's/#.*//' "$SELECTION")

# Anti-vacuity: the strip must not have eaten the file.
runtime_lines=$(grep -c '[^[:space:]]' <<< "$runtime_code" || true)
[ "$runtime_lines" -ge 80 ] || fail "only $runtime_lines code lines left in $RUNTIME after stripping comments (expected >= 80) — the strip is broken, so the absence checks below prove nothing."

# 1. runtime.exs must delegate rather than decide.
grep -q "Stacks.Storage.Selection.choose" <<< "$runtime_code" \
  || fail "$RUNTIME no longer calls Stacks.Storage.Selection.choose/2. The decision belongs in a module with tests, not inline in config."

# 2. The banned shape: a backend chosen inside a credential check.
if grep -qE 'if[^#]*System\.(get|fetch)_env!?\("(R2_|AWS_)[A-Z_]*"\)[^#]*do' <<< "$runtime_code"; then
  fail "$RUNTIME selects storage inside a credential-presence check. Credential presence is not a statement of intent — that conflation is the defect this gate exists for."
fi

# 3. No default bucket. A stack that forgets the variable must fail, not write
#    into whichever bucket a fallback name resolves to.
if grep -qE 'R2_BUCKET_NAME"[[:space:]]*,[[:space:]]*"' <<< "$runtime_code$selection_code"; then
  fail "a default bucket name is being supplied for R2_BUCKET_NAME. One bucket came to hold objects from more than one environment this way."
fi

# 4. Blank must count as absent, since System.get_env answers "" and "" is truthy.
grep -q "String.trim" <<< "$selection_code" \
  || fail "$SELECTION no longer treats a blank value as absent. System.get_env/1 answers \"\" for a variable set to nothing, and \"\" is truthy in Elixir."

# 5. Both refusals must be reachable, and proven so by a test that asserts them.
for needle in "No object storage is configured" "requires UPLOAD_DIR"; do
  grep -qF "$needle" <<< "$selection_code" \
    || fail "$SELECTION no longer refuses with: $needle"
  grep -qF "$needle" "$SELECTION_TEST" \
    || fail "no test asserts the refusal: $needle — a raise nothing exercises is a raise nobody has seen."
done

# 6. Local must stay a permitted production choice. The Stacks is self-hosted,
#    and banning Local would generalise one deployment's accident into a rule
#    that makes the platform worse for the people running it themselves.
# ⚠️ Anchored on the CASE CLAUSE, not on the bare string. The first version
# grepped for `"local"` anywhere in the file and passed a planted violation,
# because the string also occurs inside the refusal message that tells an
# operator to set STORAGE_BACKEND=local — so the gate was matching its own
# advice rather than the value actually accepted.
grep -qE '"local"[[:space:]]*->' <<< "$selection_code" \
  || fail "$SELECTION no longer accepts STORAGE_BACKEND=local as a case clause. Local is a legitimate production choice for a self-hosted operator; only choosing it ACCIDENTALLY is the defect."

echo "OK: storage selection is deliberate — delegated to a tested module, no credential-as-intent, no default bucket, blank counts as absent, both refusals tested, local still permitted."
