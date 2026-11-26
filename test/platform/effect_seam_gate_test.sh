#!/usr/bin/env bash
#
# ⛔ THE GATE'S DISTINGUISHING FEATURE IS THE DIRECTION NOBODY TESTS.
#
# `check-effect-seam.sh` is a two-directional ratchet: it fails ABOVE its
# constant (a regression) and also BELOW it (ground gained but not written
# down). The second arm is the unusual one, and it is the one a future edit
# could quietly drop — turning the ratchet back into a floor, which this
# repository has watched absorb a regression more than once. Nothing pinned it
# until this suite.
#
# ⚠️ EVERY CASE DRIVES THE REAL GATE against a disposable copy of the tree, and
# the copy is what makes that safe: the probes plant violations, and planting
# them in the working tree would contaminate anything else running. A
# reimplementation of the gate's logic here would be wrong in the same direction
# as the gate — which this project has already done once, where a probe and its
# case failed green together.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-effect-seam.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A copy of the tree the gate reads, plus the gate itself rooted at that copy.
mkdir -p "$WORK/frontend"
cp -R "$REPO_ROOT/frontend/src" "$WORK/frontend/src"
sed 's|cd "$(dirname "$0")/.."|cd "$(dirname "$0")"|' "$GATE" > "$WORK/gate.sh"
chmod +x "$WORK/gate.sh"

# ⛔ CAPTURE, THEN MATCH — NEVER `run_gate | grep`. `set -o pipefail` is on, and
# every case below drives the gate into a NON-ZERO exit on purpose. Piping makes
# the pipeline inherit that failure even when grep matched, so each probe read
# as "the gate did not fire" when it had fired perfectly. Four cases failed that
# way, and the one case expecting a GREEN run passed — which is exactly the
# pattern that makes this kind of harness bug look like a real finding.
run_gate() { (cd "$WORK" && bash gate.sh 2>&1) || true; }
# ⛔ NO PIPE, and that is the second time this one bit. Piping into `grep -q`
# under `pipefail` lets the early-exiting consumer kill the producer with
# SIGPIPE, so the pipeline reports 141 and the test goes the WRONG WAY on a
# match — the same shape as the bug this helper was written to fix. A bash
# regex match reads the captured output directly and has no producer to kill.
gate_says() { [[ "$GATE_OUT" =~ $1 ]]; }
restore() { rm -rf "$WORK/frontend/src"; cp -R "$REPO_ROOT/frontend/src" "$WORK/frontend/src"; }

test_case "gate_exists" "the script is present and parses"
assert_path_exists "$GATE" "scripts/check-effect-seam.sh exists"
if bash -n "$GATE" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so nothing below exercises the real thing"
fi

test_case "clean_tree_passes" "the committed tree sits exactly at the ratchet"
GATE_OUT="$(run_gate)"
if gate_says "^OK:"; then
    _record_pass "a tree at the ratchet is green"
else
    _record_fail "the gate is red on an unmodified tree, so every probe below is meaningless"
fi

# ── the hard direction ───────────────────────────────────────────────────────
test_case "a_regressed_module_reds" "the count may not rise"
# ⚖️ Takes a seam AWAY rather than adding a module, so the population is
# conserved and this case exercises the ratchet rather than the population
# check — which otherwise fires first and the probe proves the wrong thing.
python3 - "$WORK/frontend/src/Page/Blog/Post.elm" <<'PY2'
import re, sys
p = sys.argv[1]
t = open(p).read()
t = re.sub(r"^    , updateWithEffect\n", "", t, count=1, flags=re.M)
t = re.sub(r"^    , initWithEffect\n", "", t, count=1, flags=re.M)
open(p, "w").write(t)
PY2
GATE_OUT="$(run_gate)"
if gate_says "above the ratchet"; then
    _record_pass "a module added the old way fails immediately"
else
    _record_fail "a NEW seamless module did not red — the ratchet's main direction is dead"
fi
restore

# ── the soft direction, which is the point of this suite ─────────────────────
test_case "ground_gained_must_be_written_down" "the count may not fall silently"
# Give a seamless module a real seam, so the count genuinely falls by one.
TARGET="$WORK/frontend/src/Page/Groups/Detail.elm"
python3 - "$TARGET" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p).read()
t = t.replace("init, update, view)", "init, update, updateWithEffect, view)", 1)
t = re.sub(r"\bEffect\.perform\s*\(", "(", t)
t = t.replace("update : Msg", "updateWithEffect : Msg", 1)
t = re.sub(r"^update ", "updateWithEffect ", t, count=1, flags=re.M)
t += """

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        ( m, effect ) =
            updateWithEffect msg model
    in
    ( m, Effect.perform effect )
"""
open(p, "w").write(t)
PY
GATE_OUT="$(run_gate)"
if gate_says "but the ratchet still says"; then
    _record_pass "a real conversion fails until MAX_SEAMLESS is lowered with it"
else
    _record_fail "the BELOW-ratchet arm is gone — this is a floor now, and a floor absorbs the next regression"
fi
restore

# ── the two escapes a name check cannot see ──────────────────────────────────
test_case "a_declared_seam_that_still_performs_is_not_credited" \
    "half-converted must not read as converted"
python3 - "$TARGET" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace("init, update, view)", "init, update, updateWithEffect, view)", 1)
t += "\n\nupdateWithEffect : Int -> Int\nupdateWithEffect n =\n    n\n"
open(p, "w").write(t)
PY
GATE_OUT="$(run_gate)"
if gate_says "declare a seam and still perform"; then
    _record_pass "a five-line do-nothing seam is named, not credited"
else
    _record_fail "a fake seam reclassified a module as done and took its sites out of the count"
fi
restore

test_case "a_module_cannot_leave_the_population" \
    "an aliased import or a deletion is not ground gained"
rm -f "$WORK/frontend/src/Page/Feedback.elm"
GATE_OUT="$(run_gate)"
if gate_says "than the .* on record"; then
    _record_pass "a module leaving the corpus reds instead of shrinking the count"
else
    _record_fail "a module vanished and the gate read it as progress"
fi
restore

test_case "an_aliased_import_is_still_counted" \
    "import Effect as Fx must not hide a module's sites"
python3 - "$WORK/frontend/src/Page/Settings/Privacy.elm" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("import Effect", "import Effect as Fx", 1).replace("Effect.perform", "Fx.perform")
open(p, "w").write(t)
PY
GATE_OUT="$(run_gate)"
if gate_says "^OK:"; then
    _record_pass "aliasing changes nothing — the module and its sites stay in the accounting"
else
    _record_fail "an aliased import moved the count, so renaming the import is an escape hatch"
fi
restore

# ⛔ ANTI-VACUITY FOR THIS SUITE. Every case above asserts on gate OUTPUT, so a
# gate that printed nothing at all would fail them rather than pass — but a gate
# that could not run would too, and for the wrong reason. This separates them.
test_case "the_gate_actually_ran" "a starved tree is refused, not reported clean"
# ⚠️ The population check would fire here too, and for a defensible reason — but
# what this case is for is the anti-vacuity branch, so it accepts either refusal
# and fails only on a GREEN run over an empty corpus.
rm -rf "$WORK/frontend/src"
mkdir -p "$WORK/frontend/src"
GATE_OUT="$(run_gate)"
if gate_says "found no module calling|plan-building module"; then
    _record_pass "an empty corpus fails closed rather than reading as perfect"
else
    _record_fail "a tree with no modules did NOT fail — the gate passes on an absent subject"
fi
restore

summarise
