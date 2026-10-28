#!/usr/bin/env bash
# A spec that passes must pass again, immediately, against the same stack.
#
# ⛔ WHY THIS EXISTS, and it is a measurement defect rather than a flaky test.
# Two identical runs of `settings.spec.ts`, back to back, same stack, nothing
# changed between them:
#
#     RUN A: 1 failed  (:571)
#     RUN B: 3 failed  (:54, :109, :571)
#
# The consent toggles flip a shared seeded user's consent fields and leave them
# flipped, so the next run starts from the flipped state and asserts a
# transition it can no longer make.
#
# ⚠️ THE COST IS NOT THE FLAKINESS. This repository's standing rule is that
# every failure encountered gets fixed, and that rule assumes a stable
# denominator. Without one, a failure count is not evidence: during one session
# the suite reported 44, 34, 18, 13 and 15 failures, and part of that was real
# improvement while part was residue from the run before. The two cannot be
# separated afterwards.
#
# ⚖️ So this reports the SYMMETRIC DIFFERENCE of two runs' failure sets. That set
# is the order-dependence, and it is the thing to drive to zero — not the
# failure count. A failure in BOTH runs is a real failure and is reported
# separately rather than counted here: `:571` was one, and must not be absorbed
# into the flaky class.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT/e2e" || exit 1

if [[ -z "${BASE_URL:-}" ]]; then
    echo "FAIL: BASE_URL is unset, so there is no stack to measure against." >&2
    echo "      This check is about state a run LEAVES BEHIND, so it is meaningless" >&2
    echo "      without a persistent stack both runs share." >&2
    exit 1
fi

# ⛔ A floor on tests EXECUTED, not on failures. Two runs of zero tests have an
# empty symmetric difference and would report perfect repeatability.
#
# ⚠️ A LITERAL, NOT `${MIN_TESTS:-10}`, and the first version was the latter.
# An env-overridable floor can be set to 0 from outside, which is precisely the
# bypass `check-guard-is-unbypassable.sh` exists to find — and that gate did not
# flag it, because it only recognises a declared literal. A floor anyone can
# lower is not a floor, and the one that is invisible to the meta-gate is worse
# than one that is merely low.
MIN_TESTS=10

SPECS=("$@")
if [[ ${#SPECS[@]} -eq 0 ]]; then
    # The specs measured to mutate shared state. Named rather than "all", because
    # two full suite runs cost ~17 minutes and this has to be affordable in CI.
    SPECS=(settings.spec.ts public-profile.spec.ts)
fi

RUN_A="$(mktemp)"
RUN_B="$(mktemp)"
ERR_A="$(mktemp)"
ERR_B="$(mktemp)"
trap 'rm -f "$RUN_A" "$RUN_B" "$ERR_A" "$ERR_B"' EXIT

# ⚠️ STDERR IS KEPT, NOT DISCARDED. The first version of this function sent it
# to /dev/null, and when a run produced no report at all the check could only
# say "could not read a run's JSON report" — true, useless, and the reason WHY
# was in the stream that had just been thrown away. Discarding the stream you
# need to classify a failure is a recorded mistake in this repository.
run_once() {
    local out="$1" err="$2"
    npx playwright test "${SPECS[@]}" --project=chromium --reporter=json \
        > "$out" 2> "$err" || true
    if [[ ! -s "$out" ]]; then
        echo "FAIL: the run produced no JSON report. Its stderr was:" >&2
        sed 's/^/      /' "$err" | tail -20 >&2
        exit 1
    fi
}

echo "==> Run A over: ${SPECS[*]}"
run_once "$RUN_A" "$ERR_A"
echo "==> Run B (identical, immediately after)"
run_once "$RUN_B" "$ERR_B"

python3 - "$RUN_A" "$RUN_B" "$MIN_TESTS" <<'PY'
import json
import sys

a_path, b_path, floor = sys.argv[1], sys.argv[2], int(sys.argv[3])


def failures(path):
    """(failing test ids, tests seen, run-level errors). Ids are file:line:title.

    ⛔ THE RUN-LEVEL ERRORS ARE RETURNED, and leaving them out cost a gate run.
    A run whose `globalSetup` or `setup` project fails writes a perfectly valid
    report with `suites: []` and the reason in `errors` — so the floor below
    fired with "run B saw 0" while the sentence explaining WHY sat unread in the
    object this function had already parsed. `run_once` only prints stderr when
    the report is EMPTY, and this report was not empty, so nothing surfaced it.
    Same shape as the defect this script exists to prevent: a measurement that
    reports a number instead of a cause it was holding.

    ⚠️ The report is NOT the whole file. Playwright's json reporter writes to
    stdout, and the suite's `globalSetup` logs to stdout first — so the stream
    begins with lines like "==> globalSetup: warming …" and only then the
    object. Parsing from byte 0 fails with "Expecting value: line 1 column 1",
    which reads like a missing report rather than a prefixed one. So the object
    is located rather than assumed to start the file.
    """
    with open(path, encoding="utf-8", errors="replace") as handle:
        raw = handle.read()

    start = raw.find("{")
    if start < 0:
        raise ValueError("no JSON object anywhere in the report stream")
    report = json.loads(raw[start:])

    failed, total = set(), 0

    def walk(suites, file_hint=""):
        nonlocal total
        for suite in suites or []:
            here = suite.get("file") or file_hint
            for spec in suite.get("specs") or []:
                total += 1
                ident = f"{here}:{spec.get('line')}:{spec.get('title')}"
                if not spec.get("ok", True):
                    failed.add(ident)
            walk(suite.get("suites"), here)

    walk(report.get("suites"))
    return failed, total, report.get("errors") or []


def describe_errors(label, errors):
    if not errors:
        return
    print(f"      {label} reported {len(errors)} run-level error(s):", file=sys.stderr)
    for err in errors[:5]:
        message = (err.get("message") or str(err)).strip()
        for line in message.split("\n")[:6]:
            print(f"        {line}", file=sys.stderr)


try:
    a_fail, a_total, a_errors = failures(a_path)
    b_fail, b_total, b_errors = failures(b_path)
except (OSError, ValueError, KeyError) as exc:
    print(f"FAIL: could not read a run's JSON report ({exc}).", file=sys.stderr)
    print(
        "      Without both reports this check cannot compare anything, and an\n"
        "      unreadable report must not pass as 'no difference found'.",
        file=sys.stderr,
    )
    raise SystemExit(1)

if a_total < floor or b_total < floor:
    print(
        f"FAIL: run A saw {a_total} test(s) and run B saw {b_total}; "
        f"expected at least {floor} each.",
        file=sys.stderr,
    )
    print(
        "      Two runs of almost nothing agree perfectly. The floor is on tests\n"
        "      EXECUTED because an empty symmetric difference over an empty run is\n"
        "      the same output as real repeatability.",
        file=sys.stderr,
    )
    describe_errors("run A", a_errors)
    describe_errors("run B", b_errors)
    if not a_errors and not b_errors:
        print(
            "      ⚠️ Neither run reported a run-level error, so the specs were\n"
            "      collected and simply did not match: check the spec names above\n"
            "      against what is on disk.",
            file=sys.stderr,
        )
    else:
        print(
            "      ⚖️ A run that collected nothing failed BEFORE its first test, so\n"
            "      this is not a repeatability result — read the error above as the\n"
            "      finding. One known cause is the preceding stage: rate-limit.spec.ts\n"
            "      floods the :auth bucket, and a login here 429s until that window\n"
            "      drains.",
            file=sys.stderr,
        )
    raise SystemExit(1)

both = sorted(a_fail & b_fail)
only_a = sorted(a_fail - b_fail)
only_b = sorted(b_fail - a_fail)
difference = only_a + only_b

if both:
    print(f"FAILED IN BOTH RUNS ({len(both)}) — not order-dependent BETWEEN these two runs:")
    for ident in both:
        print(f"  {ident}")
    print(
        "  ⚠️ This check does NOT fail on these — it measures repeatability, and\n"
        "     these repeat. But read the label precisely: it means 'the same in both\n"
        "     runs', NOT 'a genuine code defect'.\n"
        "\n"
        "  ⛔ THE LIMIT THIS CHECK HAS, stated because the label invites the wrong\n"
        "     conclusion. State poisoned BEFORE both runs looks identical to a real\n"
        "     failure: a spec that created a listing in some earlier run now fails\n"
        "     every run with `HTTP 422 already exists`, deterministically, and this\n"
        "     comparison cannot see it. Measured instance: three public-profile\n"
        "     cases sat in this bucket, one of which predates the others.\n"
        "\n"
        "  ⚖️ So a failure here is a FAILURE TO DIAGNOSE, and the question to ask of\n"
        "     each is whether it fails against a FRESH stack too. If it passes there\n"
        "     and fails here, it is residue rather than a defect — the same class as\n"
        "     the set below, just older."
    )
    print()

if difference:
    print(
        f"FAIL: {len(difference)} test(s) differed between two IDENTICAL runs.",
        file=sys.stderr,
    )
    for ident in only_a:
        print(f"  failed in run A only:  {ident}", file=sys.stderr)
    for ident in only_b:
        print(f"  failed in run B only:  {ident}", file=sys.stderr)
    print(
        "\nNothing changed between the runs, so each of these is a function of what\n"
        "the previous run left behind — a shared seeded user mutated and not\n"
        "restored. Give the spec its own minted user (`mintSession` /\n"
        "`injectSession`, which is exclusive per context) rather than restoring the\n"
        "field afterwards: restoration is a second thing to keep correct and fails\n"
        "silently when it drifts.\n"
        "\n"
        "⛔ Do not add a tolerance to absorb this. A failure count is not a\n"
        "measurement while this set is non-empty, and 'fix every failure' has no\n"
        "finite meaning.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    f"OK: two identical runs agreed exactly — {a_total} test(s) each, "
    f"{len(both)} failing in both, 0 order-dependent."
)
PY
