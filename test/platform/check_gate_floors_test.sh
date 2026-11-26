#!/usr/bin/env bash
# test/platform/check_gate_floors_test.sh
#
# scripts/check-gate-floors.sh claims that no gate under scripts/check-*.sh can
# report a clean pass over a population it never read: each must carry an
# anti-vacuity FLOOR or an allowlist reason, and the meta-gate must carry a
# floor of its own. This suite pins all of that in a sandbox corpus rather than
# against the live one, so the cases stay asserted as the project's gates come
# and go.
#
# Four properties, matching the ones the gate exists to hold:
#   (a) a gate with NO detectable floor and no allowlist reason is caught;
#   (b) a gate with a floor — or an allowlist reason — passes;
#   (c) the meta-gate's OWN floor fires on a starved corpus, so an eroded or
#       broken glob is refused rather than read as "nothing violates";
#   (d) an allowlist entry whose gate GAINED a floor, or VANISHED, is reported
#       stale — the ratchet that shrinks the exemption list over time.
#
# ⛔ THE GATE IS INSTALLED WITH ITS `ALLOWLIST` EMPTIED, for the same reason the
# sibling script-wiring suite does it: a plain `cp` carries the real 16-entry
# allowlist into the sandbox, where every entry names a gate that does not exist
# here, so the stale-entry check fires ("vanished") and every case fails for a
# reason unrelated to what it asserts. The allowlist cases instead repoint ONE
# real entry at a sandbox gate, exercising the actual construct rather than a
# restatement of it.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-gate-floors.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/scripts" "$SANDBOX/bin"
# `git` shadowed so the installed gate's `git rev-parse --show-toplevel` fails
# and REPO_ROOT falls back to ".", which is the sandbox — the gate then globs
# the sandbox corpus rather than the real one.
printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/git"
chmod +x "$SANDBOX/bin/git"

# Install the real gate into the sandbox with its ALLOWLIST either EMPTIED or,
# given a path, holding exactly one real entry repointed at that sandbox gate.
# Mirrors the script-wiring suite's installer, including its anti-vacuity guard.
install_gate() {
    python3 - "$GATE" "$SANDBOX/scripts/check-gate-floors.sh" "${1:-}" <<'PREP'
import pathlib
import re
import sys

src, dst, repoint = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
text = src.read_text(encoding="utf-8")
match = re.search(r"^ALLOWLIST = \{.*?^\}\n", text, re.S | re.M)
if not match:
    raise SystemExit("HARNESS: the gate no longer declares an ALLOWLIST block")
if repoint:
    # Anti-vacuity: if the real ALLOWLIST is ever emptied, refuse rather than
    # quietly exempt nothing and pass.
    paths = re.findall(r'^\s*"([^"]+)":', match.group(0), re.M)
    if not paths:
        raise SystemExit("HARNESS: the real ALLOWLIST is empty, so this case proves nothing")
    entries = re.findall(r'^\s*"[^"]+":\s*\(.*?^\s*\),\n', match.group(0), re.S | re.M)
    if not entries:
        raise SystemExit("HARNESS: could not parse any ALLOWLIST entry")
    # Keep exactly ONE entry, repointed; drop the rest so they are not reported
    # stale for pointing at gates absent from the sandbox.
    first = entries[0].replace(paths[0], repoint)
    body = "ALLOWLIST = {\n" + first + "}\n"
else:
    body = "ALLOWLIST = {}\n"
dst.write_text(text[: match.start()] + body + text[match.end() :], encoding="utf-8")
PREP
}

# A sandbox gate carrying a floor the detector recognises (a MIN_ constant).
write_floored() {
    printf '#!/usr/bin/env bash\n# %s — carries a floor\nMIN_THINGS=5\necho "OK: fine"\n' \
        "$1" > "$SANDBOX/scripts/$1"
}

# A sandbox gate with no floor at all.
write_floorless() {
    printf '#!/usr/bin/env bash\n# %s — no floor\necho "OK: fine"\n' \
        "$1" > "$SANDBOX/scripts/$1"
}

# A bed of floored gates, enough to clear the meta-gate's own MIN_GATES floor so
# the per-gate checks actually run. Re-seeded per phase.
seed_bed() {
    rm -f "$SANDBOX/scripts/check-bed-"*.sh
    local i
    for i in $(seq 1 "$1"); do
        write_floored "check-bed-$i.sh"
    done
}

run_gate() {
    OUT="$(cd "$SANDBOX" && PATH="$SANDBOX/bin:$PATH" bash scripts/check-gate-floors.sh 2>&1)"
    RC=$?
}

install_gate

# ── (c) the meta-gate's own floor fires on a starved corpus ──────────────────

# Six gates (five bed + the meta-gate itself) is well under MIN_GATES. The point
# is that a HANDFUL trips it, not only zero: an eroded corpus reads as a pass
# exactly because its violation list is empty.
seed_bed 5

test_case "own_floor_fires_on_a_starved_corpus" \
    "the meta-gate refuses when it enumerated implausibly few gates"
run_gate
assert_exit_nonzero "$RC" "a corpus below MIN_GATES is refused, not passed"
assert_contains "$OUT" "enumerated only" "the refusal names the count it found"
assert_contains "$OUT" "This is a refusal, not a pass" \
    "and says plainly it measured nothing"

# ── every remaining case needs the floor CLEARED, so the real checks run ─────

seed_bed 50

test_case "a_floored_corpus_passes" "a corpus whose gates all carry a floor passes"
run_gate
assert_exit_zero "$RC" "every gate is floored, so the gate is satisfied"
assert_contains "$OUT" "gate(s) examined" "the summary states how many it examined"
assert_not_contains "$OUT" "enumerated only" \
    "the own-floor is cleared — the real per-gate check is what ran"

# ── (a) a floorless gate with no allowlist reason is caught ──────────────────

write_floorless "check-nofloor.sh"

test_case "a_floorless_gate_is_caught" \
    "a gate with no floor and no reason fails the meta-gate"
run_gate
assert_exit_nonzero "$RC" "the floorless gate is refused"
assert_contains "$OUT" "scripts/check-nofloor.sh" "the offending gate is named"
assert_contains "$OUT" "NO detectable anti-vacuity floor" "the output says what is wrong"
assert_not_contains "$OUT" "enumerated only" \
    "the failure is the per-gate check, not the own-floor"

# ── (a') a floor written only in a COMMENT does not count ────────────────────

# The route comment-stripping leaves open, and the reason the detector reads
# code rather than the whole file: a gate that only TALKS about refusing an
# empty population — naming every idiom the patterns look for — is still
# floorless.
cat > "$SANDBOX/scripts/check-nofloor.sh" <<'EOF'
#!/usr/bin/env bash
# This gate refuses an empty population. It would print "found no rows" and a
# MIN_ROWS floor of 5 is what it should carry, but none of that is code.
echo "OK: fine"
EOF

test_case "a_floor_only_in_a_comment_is_not_a_floor" \
    "prose describing a floor does not satisfy the gate"
run_gate
assert_exit_nonzero "$RC" "the gate with only a commented floor is still refused"
assert_contains "$OUT" "scripts/check-nofloor.sh" "the offending gate is named"
assert_contains "$OUT" "NO detectable anti-vacuity floor" \
    "comments are stripped before the floor patterns run"

# ── (b, floor half) the same gate, now with a real floor, passes ─────────────

write_floored "check-nofloor.sh"

test_case "a_gate_with_a_floor_passes" "a real floor clears the gate"
run_gate
assert_exit_zero "$RC" "the floored gate no longer fails"
assert_contains "$OUT" "gate(s) examined" "the summary reports a clean pass"

# ── (b, allowlist half) an allowlisted floorless gate passes ─────────────────

# The real gate with ONE live allowlist entry repointed at the sandbox gate, so
# this exercises the actual construct. If the real ALLOWLIST is ever emptied,
# install_gate refuses and this case fails rather than silently passing.
install_gate "scripts/check-nofloor.sh"
write_floorless "check-nofloor.sh"

test_case "the_allowlist_exempts_a_floorless_gate" \
    "an allowlisted gate with no floor does not fail the meta-gate"
assert_contains "$(cat "$SANDBOX/scripts/check-gate-floors.sh")" '"scripts/check-nofloor.sh":' \
    "precondition: a real ALLOWLIST entry was found and repointed"
run_gate
assert_exit_zero "$RC" "the allowlisted floorless gate passes"
assert_not_contains "$OUT" "stale ALLOWLIST" "and the entry is not reported stale"
assert_contains "$OUT" "allowlisted with a reason" "the verdict says the allowlist carried it"

# ── (d, gained-floor half) an allowlisted gate that gained a floor is stale ──

# ⚠️ The ratchet. An allowlisted gate that ADOPTS a floor no longer needs the
# exemption; carrying it anyway is how an allowlist ossifies into a parking lot.
write_floored "check-nofloor.sh"

test_case "an_allowlisted_gate_that_gained_a_floor_is_stale" \
    "the exemption is reported stale once the gate carries its own floor"
run_gate
assert_exit_nonzero "$RC" "a stale allowlist entry fails the gate"
assert_contains "$OUT" "stale ALLOWLIST" "the output names the stale check"
assert_contains "$OUT" "scripts/check-nofloor.sh" "and names the entry to drop"

# ── (d, vanished half) an allowlisted gate that vanished is stale ────────────

rm -f "$SANDBOX/scripts/check-nofloor.sh"

test_case "an_allowlisted_gate_that_vanished_is_stale" \
    "an entry whose gate was deleted is reported stale"
run_gate
assert_exit_nonzero "$RC" "a vanished allowlisted gate fails the gate"
assert_contains "$OUT" "stale ALLOWLIST" "the output names the stale check"
assert_contains "$OUT" "scripts/check-nofloor.sh" "and names the vanished entry"

summarise
