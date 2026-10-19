#!/usr/bin/env bash
# A retention sweep whose cost grows with how long it has been failing cannot
# keep a retention promise.
#
# ⚠️ WHAT THIS IS FOR. `GDPR.ImageRetention.cleanup_expired_images/0` selected
# every expired row with a bare `Repo.all()`, then deleted that many storage
# objects, issued one `delete_all` with an equally long id list, and emitted one
# event per row. On production that was 6,655 rows in a single run on a machine
# `min_machines_running = 0` suspends when idle.
#
# ⛔ The shape turns a missed sweep into a RATCHET. The run cannot finish before
# the machine goes away; with nothing to rescue the interrupted job it sits in
# `executing` forever; the next run faces the same backlog plus a day's growth.
# The oldest unpurged image was 151 days past its expiry when this was found.
# The defect is not "a sweep failed" — it is that failing made it less able to
# recover.
#
# So the rule is narrow and mechanical: a function whose NAME says it sweeps,
# purges, prunes or expires must not load its working set with an unbounded
# `Repo.all`. Either bound it with a `limit`, or operate set-at-a-time with a
# single `delete_all`/`update_all` that never materialises rows — both are fine,
# and the second is often better.
#
# ⚠️ NO BASELINE, deliberately. There were three instances; all three are fixed
# (the two image sweeps and the unverified-account reap), so this gate holds at
# zero. A baseline here would be the wrong trade: unlike the serializer-omission
# gate, where 98 entries are legitimate narrowing, every instance of THIS pattern
# is a latent outage, and there is no population of benign ones to pin.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import pathlib
import re
import sys

ROOT = pathlib.Path("apps/core/lib")

# A function whose name claims it clears things out. Matched on the name because
# that is the contract a reader relies on: `cleanup_expired_images` promises to
# clear expired images, and a caller has no reason to suspect it clears only
# some of them unless the signature says so.
#
# ⚠️ `defp?`, not `def`. Matching only public functions found 4 of the 8 that
# exist, which tripped the floor below — and the private half is not the safe
# half: `reap_abandoned_signups` and `maybe_purge_on_revoke` are both private and
# both do real work.
SWEEP_NAME = re.compile(
    r"\bdefp?\s+(\w*(?:cleanup|purge|sweep|prune|retention|expired|reap)\w*)\s*\(",
    re.IGNORECASE,
)

# `Repo.all(` with no `limit` anywhere in the same function body. `limit:` covers
# the keyword form inside a `from`, `limit(` the pipeline form.
LOADS_EVERYTHING = re.compile(r"\bRepo\.all\(")
BOUNDED = re.compile(r"\blimit\(|\blimit:")

files = sorted(ROOT.rglob("*.ex"))

# ⚠️ Anti-vacuity on the corpus. The result below is a list that is empty both
# when the code is correct and when nothing was read.
if len(files) < 50:
    print(
        f"FAIL: scanned only {len(files)} Elixir file(s) under {ROOT}.",
        file=sys.stderr,
    )
    print(
        "This tree holds hundreds, so a number this low means the walk is broken rather than\n"
        "that the modules are gone. Nothing was checked.",
        file=sys.stderr,
    )
    raise SystemExit(1)

sweeps_seen = 0
offenders = []

for path in files:
    src = path.read_text(encoding="utf-8", errors="replace")

    # Function bodies, sliced at the next top-level `def`/`defp`. Crude, and
    # deliberately so: a slice that runs long can only produce a FALSE PASS by
    # finding a `limit` that belongs to the next function, and a false pass here
    # is a missed latent outage. Erring the other way would mean false alarms,
    # which is how a gate gets switched off — so the slice is checked against the
    # marker below instead of being made cleverer.
    starts = [(m.start(), m.group(1)) for m in SWEEP_NAME.finditer(src)]
    boundaries = [m.start() for m in re.finditer(r"\n  defp?\s+\w", src)] + [len(src)]

    for start, name in starts:
        sweeps_seen += 1
        end = next((b for b in boundaries if b > start), len(src))
        body = src[start:end]

        if not LOADS_EVERYTHING.search(body):
            continue
        if BOUNDED.search(body):
            continue

        # An explicit, reviewed exemption on the line above the def, for a sweep
        # whose working set is provably bounded by something other than a limit.
        preceding = src[max(0, start - 300):start]
        if "BOUNDED SWEEP:" in preceding:
            continue

        offenders.append((str(path), name))

if sweeps_seen < 5:
    print(
        f"FAIL: matched only {sweeps_seen} sweep-shaped function(s).",
        file=sys.stderr,
    )
    print(
        "This app has retention, pruning and reaping functions across several contexts, so a\n"
        "number this low means the name pattern has drifted and the scan is looking at nothing.",
        file=sys.stderr,
    )
    raise SystemExit(1)

if offenders:
    print(
        f"FAIL: {len(offenders)} sweep(s) load their working set with an unbounded Repo.all:",
        file=sys.stderr,
    )
    for path, name in offenders:
        print(f"  {path}: {name}", file=sys.stderr)
    print(
        "\nA sweep like this costs more the longer it has been failing, so a missed run makes\n"
        "the next one less likely to finish. On a machine that scales to zero that is a\n"
        "ratchet: the image-retention sweep reached 6,655 rows and 151 days overdue this way.\n\n"
        "Fix it by bounding the read with a `limit` and draining across runs, or by operating\n"
        "set-at-a-time with a `delete_all`/`update_all` that never materialises rows. If the\n"
        "working set really is bounded by something else, say so in a comment above the def\n"
        "containing `BOUNDED SWEEP:` and why.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(f"OK: {sweeps_seen} sweep-shaped function(s) checked; none loads an unbounded working set.")
PY
