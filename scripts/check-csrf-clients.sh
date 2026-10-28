#!/usr/bin/env bash
# Every non-browser client that writes to our own API carries the CSRF proof.
#
# ⛔ WHY THIS EXISTS, and it is the gap that broke a CI run rather than a
# hypothetical. Double-submit CSRF enforcement was sized by enumerating the
# SERVER's state-changing routes (91 of them, 83 in scope) and the E2E harness's
# write sites. Nobody enumerated the **shell clients**, and three of them write
# to the API: `deploy-stack.sh`'s vision warmup (login, upload init, upload
# commit), `probe-production.sh`'s login latency probe, and
# `smoke-circuit-breakers.sh`'s internal POST.
#
# ⚠️ The failure was not loud in the useful way. The deploy reported
#
#     FAIL warmup: could not authenticate as warmup user (HTTP 403)
#         Check PROBE_SEED_EMAIL / PROBE_SEED_PASSWORD.
#
# which names the wrong cause entirely — the credentials were fine and the
# message sent the reader to the secrets. A 403 on a write is now ambiguous
# between "wrong password" and "no proof", and only the body distinguishes them.
#
# ⚖️ So the invariant is client-side and the mirror of the route gate's: for
# every unsafe-method `curl` aimed at our own API, the same invocation carries an
# `X-CSRF-Token` header. A route gate cannot see this, because the route is
# correctly protected — it is the caller that is wrong.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# ⛔ Floors on what was READ, not on what was found. A glob that stopped matching
# would report "no unproven clients" over a corpus it never opened, which is the
# same output as a clean run.
MIN_FILES=20
MIN_CURL_INVOCATIONS=30
MIN_IN_SCOPE=3

python3 - "$MIN_FILES" "$MIN_CURL_INVOCATIONS" "$MIN_IN_SCOPE" <<'PY'
import os
import re
import sys

min_files, min_curl, min_scope = (int(a) for a in sys.argv[1:4])

ROOTS = ["scripts", ".github"]
SUFFIXES = (".sh", ".yml", ".yaml")

# ⛔ AN EXPLICIT METHOD IS NOT THE ONLY WAY TO WRITE, and assuming it was is this
# gate's third recorded blind spot — the costliest one. `curl URL -d '{…}'`
# sends a POST with no `-X` anywhere, and two SECURITY scans were written that
# way: the jwt_tool lane's login and the IDOR lane's. Both were refused by CSRF
# enforcement, both failed to obtain a token, and both then SKIPPED — so the
# scanners went dark while this gate reported every client proven.
#
# ⚖️ So the question is "does this request carry a body or an upload", not "does
# it name a method": `-d/--data*`, `-F/--form`, and `-T/--upload-file` each
# imply POST or PUT. `-G` is the exception that proves the rule — it turns `-d`
# back into a query string on a GET — so it is excluded explicitly.
_BODY_FLAGS = r"-d\b|--data(-binary|-raw|-urlencode|-ascii)?\b|-F\b|--form\b|-T\b|--upload-file\b"
UNSAFE_METHOD = re.compile(
    r"-X\s*(POST|PUT|PATCH|DELETE)\b|--request\s*(POST|PUT|PATCH|DELETE)\b", re.I
)
BODY_IMPLIES_WRITE = re.compile(_BODY_FLAGS)
QUERY_NOT_BODY = re.compile(r"(^|\s)-G\b|--get\b")


def is_unsafe(call):
    """True when the invocation sends a state-changing request."""
    if UNSAFE_METHOD.search(call):
        return True
    if QUERY_NOT_BODY.search(call):
        return False
    return bool(BODY_IMPLIES_WRITE.search(call))
HEADER = re.compile(r"x-csrf-token", re.I)

# ⚠️ Hosts that are NOT our API. A proof means nothing to them and sending one
# would leak it to a third party, so these are out of scope rather than exempt.
#
# ⛔ `upload_url` IS NOT IN THIS LIST, AND WAS, WHICH IS THE GATE'S SECOND
# RECORDED BLIND SPOT. It was excluded on the strength of its NAME — "that is a
# presigned object-storage URL" — and the deploy warmup's PUT to it is a request
# to OUR OWN API on this stack: `/api/upload/init` returns a RELATIVE
# `upload_url`, which the script resolves against `${CORE_URL}`. The exclusion
# hid a real violation, and it surfaced as six lines of
# "PUT to upload_url returned 403" read as a broken object store.
#
# ⚖️ Whether that URL is ours is decided at RUNTIME, so a static gate cannot
# classify it — which is why the call site resolves it into an explicit branch
# and only the our-origin arm carries the proof.
#
# ⚠️ STATED PLAINLY BECAUSE IT IS A REAL LIMIT: the arm that does NOT carry the
# proof matches neither list, so it is **unclassified rather than reported** —
# this gate does not check it either way. What the removal buys is that the name
# `upload_url` no longer silently exempts a call that IS to our API; what it
# does not buy is coverage of a runtime-resolved origin. That half is pinned by
# `test/platform/csrf_clients_gate_test.sh` asserting the branch exists at the
# one site that has this shape, which is a weaker guarantee than the gate's and
# is the honest ceiling for a static scan.
#
# ⚠️ VictoriaMetrics is in this list and is reached over `localhost`, which the
# OURS rule below also matches — so it is named explicitly rather than left to
# the host test. `/api/v1/import/prometheus` on the metrics proxy ports is the
# push endpoint of the metrics STORE, a different service that has never heard
# of this application's CSRF cookie.
FOREIGN = re.compile(
    r"console\.neon\.tech|api\.fly\.io|api\.machines\.dev|\.modal\.run|modal\.com"
    r"|cloudflarestorage|amazonaws|hooks\.slack"
    r"|/api/v1/import|localhost:1842[0-9]|localhost:8428",
    re.I,
)
# ⛔ CLASSIFIED BY THE HOST VARIABLE, NOT BY A LITERAL `/api/` PATH, and the
# first version of this gate got that wrong. `smoke-circuit-breakers.sh` posts
# to `"$BASE_URL${SMOKE_PATH}"` — the path is a variable, so there is no `/api/`
# in the source text and the call fell straight out of scope. A planted red run
# caught it: removing that call's header left this gate green.
#
# ⚠️ So the question is "does this URL point at the stack this repo deploys",
# which is answered by the variable naming the host, and the path is irrelevant.
OURS = re.compile(
    r"/api/|localhost|127\.0\.0\.1"
    r"|\$\{?(BASE_URL|CORE_URL|SMOKE_URL|PREVIEW_URL|STACK_URL|APP_URL"
    r"|_core_url|_base_url|core_url|base_url)\b",
    re.I,
)


def strip_comments(text, is_yaml):
    """Blank comment bodies, keeping line structure so line numbers stay true.

    ⛔ REQUIRED, NOT A REFINEMENT. This gate's subject matter IS its keywords:
    the header name appears in the prose of every comment explaining the rule,
    including this file's own header and the explanations now sitting beside
    each fixed call site. A sibling gate shipped without this and reported the
    one correctly-declared request in a file as its violation, quoting the
    comment that said why it was not one.
    """
    out = []
    for line in text.split("\n"):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            out.append("")
            continue
        # An inline `#` is only a comment outside quotes; YAML and shell agree
        # closely enough for this purpose, and over-stripping would only ever
        # HIDE a violation, so a conservative rule is checked below by the floor.
        if " #" in line and line.count('"') % 2 == 0 and line.count("'") % 2 == 0:
            line = line.split(" #", 1)[0]
        out.append(line)
    return "\n".join(out)


def invocations(text):
    """Yield (line_no, joined_text) for each curl call, following continuations."""
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        if re.search(r"\bcurl\b", lines[i]):
            start = i
            parts = [lines[i]]
            # a trailing backslash continues the command
            while parts[-1].rstrip().endswith("\\") and i + 1 < len(lines):
                i += 1
                parts.append(lines[i])
            yield start + 1, " ".join(parts)
        i += 1


files = []
for root in ROOTS:
    for dirpath, _dirs, names in os.walk(root):
        if ".venv" in dirpath or "node_modules" in dirpath:
            continue
        for name in sorted(names):
            if name.endswith(SUFFIXES):
                files.append(os.path.join(dirpath, name))
files.sort()

if len(files) < min_files:
    print(
        f"FAIL: scanned only {len(files)} file(s) under {', '.join(ROOTS)}; "
        f"expected at least {min_files}.",
        file=sys.stderr,
    )
    print(
        "      A clean result over a corpus this small is the walk having drifted, not the\n"
        "      clients having become safe — and those are the same output if the floor is on\n"
        "      findings instead of on files.",
        file=sys.stderr,
    )
    raise SystemExit(1)

total_curl = 0
in_scope = []
violations = []

for path in files:
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = strip_comments(handle.read(), path.endswith((".yml", ".yaml")))
    for line_no, call in invocations(text):
        total_curl += 1
        if not is_unsafe(call):
            continue
        if FOREIGN.search(call):
            continue
        if not OURS.search(call):
            continue
        in_scope.append((path, line_no))
        if not HEADER.search(call):
            violations.append((path, line_no, " ".join(call.split())[:110]))

if total_curl < min_curl:
    print(
        f"FAIL: found only {total_curl} curl invocation(s) across {len(files)} file(s); "
        f"expected at least {min_curl}.",
        file=sys.stderr,
    )
    print(
        "      The continuation-following parser is the part most likely to silently stop\n"
        "      matching, and a parser that finds nothing reports every client as clean.",
        file=sys.stderr,
    )
    raise SystemExit(1)

if len(in_scope) < min_scope:
    print(
        f"FAIL: only {len(in_scope)} unsafe-method call(s) to our own API were classified "
        f"in scope; expected at least {min_scope}.",
        file=sys.stderr,
    )
    print(
        "      Three are known to exist (the vision warmup's login, the production probe's\n"
        "      login, and the circuit-breaker smoke POST). Fewer means the scope rule stopped\n"
        "      recognising our own API — most likely a URL variable this gate does not know.",
        file=sys.stderr,
    )
    raise SystemExit(1)

if violations:
    print(
        f"FAIL: {len(violations)} non-browser client(s) write to our API without the proof:",
        file=sys.stderr,
    )
    for path, line_no, call in violations:
        print(f"  {path}:{line_no}", file=sys.stderr)
        print(f"      {call}", file=sys.stderr)
    print(
        "\nState-changing API requests are refused without a double-submit proof. Fetch a\n"
        "page with `--cookie-jar`, read `stacks_csrf` from it, and send it back as\n"
        "`-H \"X-CSRF-Token: $proof\"` along with `-b \"$jar\"`.\n"
        "\n"
        "⛔ This is not style. The request will be refused with 403, and a 403 on a write is\n"
        "ambiguous: the deploy warmup's own message blamed PROBE_SEED_EMAIL and sent the\n"
        "reader to the secrets while the credentials were correct all along.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    f"OK: {len(in_scope)} unsafe-method call(s) to our own API all carry the CSRF proof; "
    f"{total_curl} curl invocation(s) across {len(files)} file(s) scanned."
)
PY
