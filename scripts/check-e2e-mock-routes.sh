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

routes=$(mktemp); mocked=$(mktemp)
trap 'rm -f "$routes" "$mocked"' EXIT

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
python3 - <<'PYEOF' > "$mocked"
import re, glob

ROUTE = re.compile(r'page\.route\(\s*(`[^`]*`|"[^"]*"|\'[^\']*\')')
CONST = re.compile(r'const\s+(\w+)\s*=\s*(`[^`]*`|"[^"]*"|\'[^\']*\')')
HOLE = re.compile(r'\$\{([^}]*)\}')

out = set()
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

n_mocked=$(grep -c . "$mocked")
n_routes=$(grep -c . "$routes")

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
