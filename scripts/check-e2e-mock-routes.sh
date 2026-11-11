#!/usr/bin/env bash
#
# Every path an E2E spec MOCKS must be a path the application actually serves.
#
# ⛔ WHY THIS EXISTS. `upload-pipeline.spec.ts` mocked
# `/__mock_r2_put__/<id>` — a presigned object-storage URL the client had not
# requested since July. `Uploads.init_upload/2` returns `/api/upload/<id>/data`,
# a path on our own origin, and the client builds it from the image id. So the
# spec routed a path nothing requests, the client's real PUT went unmocked, and
# 25 of 34 cases failed reporting `not-sent`.
#
# ⚖️ The failure mode this guards is not "a test is red". It is that a mock can
# go on describing a contract the application has left, and a red suite then
# says the CLIENT is broken when the MOCK is. Those have opposite repairs, and
# applying the wrong one here would have reintroduced the CSRF refusal that the
# imageId change exists to prevent.
#
# A mocked path that matches no route is either drift or a deliberate
# off-origin fixture; the latter declares itself in ALLOWED_OFF_ORIGIN below.
set -uo pipefail
cd "$(dirname "$0")/.."

# Fixtures that are deliberately not our routes: external origins and
# data/blob URLs a spec fabricates to test how the client handles them.
ALLOWED_OFF_ORIGIN='^(https?://|data:|blob:)'

# Paths a spec mocks BECAUSE nothing serves them — testing how the client
# handles a dead resource needs a dead resource. Each one states why, because
# an unexplained entry here is indistinguishable from the drift being guarded.
#
#   /images/a-cover-that-does-not-exist.jpg
#       the broken-cover fixture: the spec fulfils it with a 404 to drive the
#       cover's fallback. A path that resolved would defeat the case.
ALLOWED_DELIBERATELY_ABSENT='^/images/a-cover-that-does-not-exist\.jpg$'

routes=$(mktemp); mocked=$(mktemp); unres=$(mktemp)
trap 'rm -f "$routes" "$mocked" "$unres"' EXIT

# The application's real paths, with Phoenix's :params as a wildcard.
mix_bin=$(command -v mix || true)
if [[ -z "$mix_bin" ]]; then
    # ⛔ FAIL, NOT SKIP. This gate runs inside the pinned shell, where mix is
    # always present; a silent skip would turn "the toolchain was missing" into
    # "the mocks are fine", which is the one answer it must never give.
    echo "FAIL check-e2e-mock-routes.sh — no mix on PATH; run via 'just run'" >&2
    exit 1
fi
mix phx.routes CoreWeb.Router 2>/dev/null \
  | grep -oE '/[a-zA-Z0-9_./:*-]+' \
  | grep -E '^/api/' \
  | sed -E 's/:[a-zA-Z_]+/*/g' \
  | sort -u > "$routes"

if [[ ! -s "$routes" ]]; then
    echo "FAIL check-e2e-mock-routes.sh — could not read the route table; the guard would pass vacuously" >&2
    exit 1
fi

# Every path an E2E spec mocks.
#
# ⛔ CONSTANTS ARE RESOLVED FIRST, AND THAT IS NOT A REFINEMENT. The drift this
# guard exists for was written `page.route(`**${UPLOAD_PUT_PATH}`)` — the whole
# pattern was one interpolation. A text-only extractor saw `**`, dropped it as
# not-a-path, and reported "all resolve" with the defect sitting in front of it.
# The planted-violation run is what exposed that; a guard blind to its own
# founding case is worse than no guard, because it is cited as cover.
UNRES_FILE="$unres" python3 - <<'PYEOF' > "$mocked"
import os, re, glob

# A JS regex literal is a legitimate route pattern and not a path, so it is
# excluded from the unresolved report rather than counted as a hole in the check.
REGEX_LITERAL = re.compile(r"^/.*/[gimsuy]*$")

ROUTE = re.compile(r'page\.route\(\s*(`[^`]*`|"[^"]*"|\'[^\']*\')')
CONST = re.compile(r'const\s+(\w+)\s*=\s*(`[^`]*`|"[^"]*"|\'[^\']*\')')
HOLE = re.compile(r'\$\{([^}]*)\}')

out = set()
unresolved = []
for path in sorted(glob.glob("e2e/tests/*.ts")):
    src = open(path).read()
    # One level of same-file constant resolution: enough for the real corpus,
    # and a nested hole stays a wildcard rather than silently vanishing.
    consts = {name: val[1:-1] for name, val in CONST.findall(src)}

    def resolve(text, depth=0):
        def sub(m):
            inner = m.group(1).strip()
            if depth < 3 and inner in consts:
                return resolve(consts[inner], depth + 1)
            return "*"
        return HOLE.sub(sub, text)

    for raw in ROUTE.findall(src):
        pat = resolve(raw[1:-1])
        pat = re.sub(r"^\*\*", "", pat)
        if pat.startswith("/"):
            out.add(pat)
        elif not REGEX_LITERAL.match(raw[1:-1]):
            # ⛔ REPORTED, NOT DROPPED, and this is the gate's own founding
            # lesson applied to itself. The original drift was written
            # `page.route(`**${UPLOAD_PUT_PATH}`)`; an extractor that silently
            # discarded what it could not reduce to a path turned that into
            # `**`, failed the startswith check, and left NO trace — so the
            # count read as a clean corpus with the defect in front of it.
            #
            # An unresolvable pattern is not itself a violation. It is a hole in
            # the check, which is worse, because a hole reports success.
            unresolved.append((path, raw[1:-1]))

with open(os.environ["UNRES_FILE"], "w") as fh:
    for path, raw in unresolved:
        fh.write(f"{path}\t{raw}\n")

print("\n".join(sorted(out)))
PYEOF

problems=0
while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    if [[ "$m" =~ $ALLOWED_OFF_ORIGIN ]]; then continue; fi
    if [[ "$m" =~ $ALLOWED_DELIBERATELY_ABSENT ]]; then continue; fi
    # A mocked pattern matches a route if, segment for segment, each part is
    # equal or either side is a wildcard. Trailing `*` on the mock (e.g.
    # `/api/bookshelves/library*`) matches within a segment too.
    if ! awk -v pat="$m" '
        function seg_ok(a, b) {
            if (a == b) return 1
            if (a == "*" || b == "*") return 1
            # A RUN of asterisks, not one: `audit-log**` is a real pattern and
            # stripping a single `*` left `audit-log*`, which matched nothing.
            if (a ~ /\*+$/) { sub(/\*+$/, "", a); return index(b, a) == 1 }
            if (b ~ /\*+$/) { sub(/\*+$/, "", b); return index(a, b) == 1 }
            return 0
        }
        BEGIN { np = split(pat, P, "/") }
        {
            nr = split($0, R, "/")
            if (nr != np) next
            for (i = 1; i <= np; i++) if (!seg_ok(P[i], R[i])) next
            found = 1; exit
        }
        END { exit(found ? 0 : 1) }
    ' "$routes"; then
        echo "  MOCKS A PATH NOTHING SERVES: $m" >&2
        problems=$((problems + 1))
    fi
done < "$mocked"

n_mocked=$(grep -c . "$mocked" || true)
n_routes=$(grep -c . "$routes" || true)
n_unres=$(grep -c . "$unres" 2>/dev/null || true)
n_unres=${n_unres:-0}

# A FLOOR ON THE MOCKED CORPUS, which this gate shipped without.
#
# The route table above already refuses to be empty, with the comment "the
# guard would pass vacuously". That reasoning was not applied to the OTHER
# input, and it is the input that can silently stop matching: a change to how
# the specs spell `page.route` would leave this printing "0 mocked path(s)
# checked ... all resolve" and exiting 0. Measured, not supposed.
#
# Deliberately well under the real figure so an ordinary spec change does not
# need to edit it, while still refusing a corpus that has collapsed.
MIN_MOCKED_PATHS=8
if [[ $n_mocked -lt $MIN_MOCKED_PATHS ]]; then
    echo "FAIL: parsed only $n_mocked mocked path(s) from e2e/tests/*.ts; expected at least $MIN_MOCKED_PATHS." >&2
    echo "      A clean result over a corpus this small is the extractor having drifted from" >&2
    echo "      how the specs spell page.route, not the mocks having become correct — and the" >&2
    echo "      two are indistinguishable if nothing floors the population." >&2
    exit 1
fi

if [[ $n_unres -gt 0 ]]; then
    echo "FAIL: $n_unres mocked pattern(s) could not be reduced to a path, so this gate" >&2
    echo "      cannot say whether they resolve:" >&2
    sed 's/^/  /' "$unres" >&2
    echo "" >&2
    echo "      Give the pattern a literal path, or define its constant in the SAME file." >&2
    echo "      A constant imported from another module is invisible to this extractor," >&2
    echo "      and a pattern it cannot read is a hole that would otherwise report success." >&2
    exit 1
fi

if [[ $problems -gt 0 ]]; then
    cat >&2 <<MSG

$problems mocked path(s) match no route in CoreWeb.Router.

A mock describing a contract the app has left makes a red suite accuse the
client of a fault that is the mock's. Either point the mock at the path the
client really requests, or — if it is deliberately off-origin — give it an
absolute URL so it declares itself.
MSG
    exit 1
fi

echo "E2E mock routes: $n_mocked mocked path(s) checked against $n_routes API route(s), all resolve."
