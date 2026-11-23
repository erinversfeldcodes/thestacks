#!/usr/bin/env bash
# Every gate refuses a starved population; so does the one that checks for it.
#
# The recurring shape in this repository is a guarantee written once and not
# inherited: a floor added to the one gate where the gap was noticed, while a
# gate 150 lines away with the same gap gets none of it. Fixing those one at a
# time reproduces the pattern. What fixes OMISSION is enumeration — not a
# `require_population` helper you must remember to call, which has the same
# discovery problem as the conditional you forgot to write, but a gate that
# walks the whole corpus and asks each member for the property.
#
# WHAT IT CHECKS  Every scripts/check-*.sh either carries an anti-vacuity FLOOR
# or an ALLOWLIST entry naming why it needs none. A floor is a sentinel of the
# "refuse an empty or starved population" kind:
#
#   * a named minimum/expected count constant — MIN_*, EXPECTED_*, MINIMUM,
#     ABSOLUTE_MIN — assigned a number or compared against one;
#   * a numeric floor on a parsed population — `len(...) < N`, `(( n < N ))`,
#     `-lt N`, `-ge N`;
#   * an empty-population refusal message — `found no …`, an empty-array
#     `${#ARR[@]} -eq 0` guard, or a counter compared to zero;
#   * the standardised refusal sentinel `This is a refusal/SKIP, not a pass`.
#
# A gate with no detectable floor FAILS unless it carries an ALLOWLIST entry
# with a written reason. The allowlist RATCHETS: an entry whose gate later
# gains a floor (or vanishes) is reported stale and must be removed, so the
# exemption list shrinks as gates adopt floors rather than sitting forever.
#
# ⛔ THE META-GATE CARRIES ITS OWN FLOOR. An empty violation list over an
# eroded corpus reads as a pass: if the corpus glob returned nothing, every
# member would trivially satisfy "has a floor or a reason" and this gate would
# announce success having examined nothing. So it refuses first if it
# enumerated implausibly few gates — the same guard it demands of the corpus.
#
# ⚠️ Floor detection is a SOURCE grep over comment-stripped code, so it is
# necessarily approximate: a floor written in a shape the patterns do not know
# is a false negative (the gate still protects its population; it just sits on
# the allowlist until someone widens the patterns), and the reverse cannot
# happen for prose because whole-line comments are stripped before matching —
# a gate that only TALKS about refusing an empty population does not pass.
#
#   check-gate-floors.sh
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1
python3 - <<'PY'
import glob
import os
import re
import sys

# The meta-gate's own floor. The real corpus is ~50; this sits below it with
# headroom for ordinary churn, high enough that a broken glob (zero or a
# handful of gates) is refused rather than read as "nothing violates".
MIN_GATES = 45

# A line matching ANY of these — in comment-stripped code — is a floor signal.
# Calibrated against the real corpus: each pattern fires on a genuine floor in
# at least one gate, and none fires on a format-width specifier (`{x:<12}`) or a
# parser-depth comparison (`depth == 0`), which were the false positives a
# broader net produced.
FLOOR_PATTERNS = [
    # a named minimum/expected count constant, assigned a number
    re.compile(r"\b(?:MIN|EXPECTED|MINIMUM|ABSOLUTE_MIN)_?[A-Z0-9_]*\s*=\s*[\"']?\$?\{?[^=\n]*\d"),
    # a comparison against such a constant
    re.compile(r"(?:<|-lt|-ge|-gt|>)\s*[\"']?\$?\{?(?:MIN|EXPECTED|MINIMUM|ABSOLUTE_MIN)_"),
    # a python length floor: len(x) < N
    re.compile(r"\blen\s*\([^)]*\)\s*<\s*\d"),
    # a bash arithmetic floor: (( n < N )), -lt N, -ge N, -gt N
    re.compile(r"\(\(\s*[A-Za-z_][A-Za-z0-9_ ]*<\s*\d|-lt\s+\$?\{?\d|-ge\s+\$?\{?\d|-gt\s+\$?\{?\d"),
    # an empty-population refusal message
    re.compile(r"found\s+no\b", re.I),
    # the standardised refusal sentinel
    re.compile(r"(?:refusal|SKIP),\s*not\s+a\s+pass", re.I),
    # an empty-array guard: ${#ARR[@]} -eq 0
    re.compile(r"\$\{#[A-Za-z_][A-Za-z0-9_]*\[@\]\}\s*-eq\s+0"),
    # a counter compared to zero / below one — "nothing was inspected"
    re.compile(
        r"\b(?:checked|examined|inspected|scanned|seen|counted|matched|ran|setters|"
        r"workers|watched|processed|permitted|covered|narrowing|sweeps_seen|"
        r"authenticated_requests|n_[a-z]+|num_[a-z]+)\s*(?:==\s*0|<\s*[15])\b"
    ),
]

# Gates with no detectable floor, each with the reason it needs none — or, where
# it does need one, the floor it still owes. A stale entry (the gate gained a
# floor, or vanished) fails the gate, so this list is pressure, not a parking lot.
ALLOWLIST = {
    # ── Structurally floor-exempt: no harvested population to starve ──────────
    "scripts/check-axis-coverage.sh": (
        "No harvested population. It keys on the changed-file set of ONE diff and "
        "already fails closed when the base ref will not resolve ('the changed set "
        "is UNKNOWN', exit 1). A legitimately empty diff — base resolves, nothing "
        "changed — is the normal 'nothing to review' case, so a count floor would "
        "red every no-op PR rather than catch a starved corpus."
    ),
    "scripts/check-idor-response.sh": (
        "Not a population gate: it classifies a single HTTP status from one live "
        "cross-user DELETE. The catch-all case already REFUSES anything that is not "
        "2xx/403/404 — a 000 connection-refused, a 5xx, a redirect — as 'the probe "
        "did not reach the authorization check, so this run proves nothing' (exit "
        "1). Nothing to count, and the unreachable case is already fail-closed."
    ),
    "scripts/check-schema-diff.sh": (
        "A destructive-change detector over a before/after schema pair, not a "
        "corpus. An empty result means the migration is additive-only, which is the "
        "pass it exists to grant — a count floor would red every additive migration. "
        "The two snapshots are arguments; a missing one is a caller error (usage, "
        "exit 2), not a silent pass over nothing."
    ),
    "scripts/check-version-drift.sh": (
        "A fixed equality check — the running Elixir/OTP version against the two "
        "values pinned in .versions — with no harvested population. A missing "
        ".versions exits 1; an absent toolchain is a declared SKIP. Neither a "
        "starved corpus nor a vacuous pass is reachable."
    ),
    # ── Floor still owed: these CAN pass over an unread population today ───────
    # Each names the vacuous success it can currently emit and the floor shape
    # that would close it. Several fail closed today only by an unhandled
    # exception on their anchor read — an accident a glob would erase.
    "scripts/check-css.sh": (
        "No count floor yet. Its population is the rules parsed from "
        "frontend/css/main.css; were that file to parse to zero rules the "
        "specificity checks are all empty set-differences and it exits 0. Floor "
        "shape: refuse unless the parsed-rule count clears a minimum, as the "
        "sibling contrast gate does with 'if checked == 0'. Fails closed today "
        "only by an unhandled FileNotFoundError on the anchor read."
    ),
    "scripts/check-css-values.sh": (
        "No count floor yet — same family as the CSS specificity gate: the colour "
        "and spacing checks are set-differences over the rules parsed from "
        "frontend/css/main.css, empty-when-correct and empty-when-starved alike. "
        "Floor shape: assert the parsed-rule count clears a minimum."
    ),
    "scripts/check-mapping-truth.sh": (
        "No count floor yet. It validates citations parsed from "
        "docs/implementation-mapping.md; zero citations would print 'OK: 0 "
        "route/module citation(s)'. Floor shape: refuse unless the citation count "
        "clears a minimum. Fails closed today only by an unhandled FileNotFoundError."
    ),
    "scripts/check-oban-queue-drift.sh": (
        "No count floor yet. It compares Oban queues parsed from the config against "
        "the doc table; a parse yielding zero queues would print 'OK: 0 Oban "
        "queue(s)'. Floor shape: assert the parsed-queue count clears a minimum."
    ),
    "scripts/check-orphan-classes.sh": (
        "No count floor yet. Its population is the class literals globbed from "
        "frontend/src; an empty glob yields zero tokens, zero orphans and exit 0. "
        "Floor shape: assert the scanned-file or token count clears a minimum. The "
        "existing 'budget' is a CEILING on orphans, not a floor on the population."
    ),
    "scripts/check-phase-scheme.sh": (
        "No count floor yet. It validates the Phase cells parsed from "
        "docs/implementation-mapping.md; zero cells would print 'OK: 0 story Phase "
        "cell(s)'. Floor shape: assert the parsed-cell count clears a minimum."
    ),
    "scripts/check-prose-assertions.sh": (
        "No count floor yet. Its population is the negative assertions globbed from "
        "frontend/tests against the literals in frontend/src; an empty glob yields "
        "no findings and exit 0. Floor shape: assert the scanned-file or "
        "source-literal count clears a minimum."
    ),
    "scripts/check-public-route-metering.sh": (
        "No count floor yet. It parses routes from the router; zero parsed routes "
        "would pass as 'every anonymously-reachable route is metered'. Floor shape: "
        "assert the parsed-route count clears a minimum. Fails closed today only by "
        "an unhandled FileNotFoundError on the anchor read."
    ),
    "scripts/check-route-clients.sh": (
        "No count floor yet. It walks the app for API routes and their client call "
        "sites; zero parsed routes would pass as 'every API route has a client call "
        "site'. Floor shape: assert the parsed-route count clears a minimum."
    ),
    "scripts/check-route-reachability.sh": (
        "No count floor yet. It parses routes from the Elm entrypoint and route "
        "module; zero parsed routes would print 'OK: all 0 linkable route(s) are "
        "reachable'. Floor shape: assert the parsed-route count clears a minimum."
    ),
    "scripts/check-script-wiring.sh": (
        "No count floor yet — and it is itself a sibling meta-gate, so the gap is "
        "pointed. It enumerates scripts for callers; an empty glob yields zero "
        "scripts, zero orphans and 'OK: 0 script(s) all wired'. Floor shape: refuse "
        "unless the enumerated-script count clears a minimum, exactly as this gate "
        "guards its own corpus with MIN_GATES."
    ),
    "scripts/check-tracker-refs.sh": (
        "No count floor yet. Its population is the git-tracked files it scans for "
        "tracker references; an empty listing (or a git failure) yields zero files "
        "and 'OK: no tracker references in code'. Floor shape: assert the "
        "tracked-file count clears a minimum. Fails closed today only by an "
        "unhandled CalledProcessError when git is unavailable."
    ),
}


def code_lines(txt):
    # Strip whole-line comments (shell/python `#`), matching the sibling wiring
    # gate. A floor expressed only in prose is not a floor, and the explanatory
    # comments here name every idiom the patterns look for — so a gate that
    # merely describes refusing an empty population must not read as floored.
    return [ln for ln in txt.split("\n") if not ln.lstrip().startswith("#")]


def has_floor(path):
    try:
        code = "\n".join(code_lines(open(path, encoding="utf-8", errors="ignore").read()))
    except OSError:
        return False
    return any(p.search(code) for p in FLOOR_PATTERNS)


gates = sorted(glob.glob("scripts/check-*.sh"))

# ── own floor: refuse an implausibly small corpus ────────────────────────────
if len(gates) < MIN_GATES:
    print(
        f"FAIL: enumerated only {len(gates)} gate(s) under scripts/check-*.sh — "
        f"the floor is {MIN_GATES}.",
        file=sys.stderr,
    )
    print(
        "      A broken glob or an eroded corpus yields an empty violation list, "
        "which reads as a pass. This is a refusal, not a pass.",
        file=sys.stderr,
    )
    sys.exit(1)

floorless = [g for g in gates if not has_floor(g)]
missing = [g for g in floorless if g not in ALLOWLIST]
stale = sorted(k for k in ALLOWLIST if k not in gates or has_floor(k))

failed = False
if missing:
    failed = True
    print(
        f"FAIL: {len(missing)} gate(s) with NO detectable anti-vacuity floor and no "
        "allowlist reason:",
        file=sys.stderr,
    )
    for g in missing:
        print(f"  {g}", file=sys.stderr)
    print(
        "\nGive it a floor (a MIN_/EXPECTED_ count, a `len(...) < N` or `(( n < N ))` "
        "refusal, a `found no …` message, or the `This is a refusal, not a pass` "
        "sentinel), or add an ALLOWLIST entry naming why it needs none.",
        file=sys.stderr,
    )
if stale:
    failed = True
    print(
        f"FAIL: {len(stale)} stale ALLOWLIST entr(y/ies) — the gate vanished, or it "
        "GAINED a floor and no longer needs the exemption:",
        file=sys.stderr,
    )
    for g in stale:
        print(f"  {g}", file=sys.stderr)
    print(
        "\nRemove the entry. A gate that adopted a floor is the ratchet working — "
        "drop its line.",
        file=sys.stderr,
    )
if not failed:
    floored = len(gates) - len(floorless)
    print(
        f"OK: {len(gates)} gate(s) examined — {floored} carry an anti-vacuity floor, "
        f"{len(floorless)} allowlisted with a reason."
    )
sys.exit(1 if failed else 0)
PY
