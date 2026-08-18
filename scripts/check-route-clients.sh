#!/usr/bin/env bash
#
# check-route-clients.sh — every API route must have a client that calls it.
#
# WHAT IT CHECKS
#   Enumerates the API routes declared in apps/core/lib/core_web/router.ex, then
#   enumerates every path the first-party clients actually request — the Elm SPA
#   (frontend/src/**/*.elm, including paths assembled with ++ and Url.Builder)
#   and the Playwright suite (e2e/**/*.ts, request/fetch/goto call sites only).
#   A route with no call site fails the build unless scripts/route-clients-allowlist.txt
#   records a reason for its absence. Allowlist entries that no longer apply — the
#   route was deleted, or it grew a caller — fail too, so the file cannot rot.
#
# WHY IT EXISTS
#   "~18 API routes have no client caller" lived as prose in a recon note. Three
#   weeks later two of that list's members shipped as user-facing defects: the
#   endpoint was there, nothing ever called it, and no test noticed because every
#   layer passed on its own. Prose does not gate. This does.
#
# WHO CALLS IT
#   scripts/lint-elixir.sh (first check, before any mix invocation), which is run
#   by `just lint-elixir`, `just verify`, and the elixir group of `just ci`.
#   Directly: `just check-route-clients` or `bash scripts/check-route-clients.sh`.
#   `bash scripts/check-route-clients.sh --report` prints the full inventory —
#   every route, its call site, and how it matched — which is how you seed or
#   re-justify the allowlist.
#
# KNOWN LIMITS (stated so nobody mistakes a pass for more than it is)
#   - Matching is by path, not by verb. A second verb added to a path that
#     already has a caller is not caught.
#   - A route with a :param segment is satisfied by a call site that hardcodes
#     that segment, because tests legitimately hardcode ids.
#   - A call site in an Elm module that nothing routes to still counts. This
#     gate answers "does anything call it", not "is that caller reachable".

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1
MODE="${1:-check}"

python3 - "$MODE" <<'PY'
import fnmatch
import os
import re
import sys

MODE = sys.argv[1] if len(sys.argv) > 1 else "check"

ROUTER = "apps/core/lib/core_web/router.ex"
ALLOWLIST = "scripts/route-clients-allowlist.txt"
ELM_ROOT = "frontend/src"
ELM_ENTRY = "Main"
TS_ROOTS = ["e2e"]
JS_ROOTS = ["apps/core/assets/js"]

# Every allowlist reason must open with one of these, then ": ", then prose that
# says which caller (or which decision) stands in for the missing client.
REASON_TAGS = (
    "test-helper-only",
    "server-route-not-SPA",
    "server-issued-url",
    "webhook",
    "deliberate-dark",
    "known-defect",
)
# known-defect is debt, not a justification: it keeps the build green while the
# missing client is tracked, and every run prints it back as a warning.
DEBT_TAG = "known-defect"

MARK = "\x01"  # one dynamic run of text inside a path built by concatenation
STR_OPEN = "\x00"


# --------------------------------------------------------------------------
# Lexing: replace string literals with placeholders so concatenation chains can
# be walked without tripping over quotes, comments, or line breaks.
# --------------------------------------------------------------------------


def lex_elm(src):
    """Strip Elm comments; return (code, strings) with literals placeheld."""
    strings = []
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "-" and src.startswith("--", i):
            while i < n and src[i] != "\n":
                i += 1
        elif c == "{" and src.startswith("{-", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if src.startswith("{-", i):
                    depth, i = depth + 1, i + 2
                elif src.startswith("-}", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            out.append(" ")
        elif src.startswith('"""', i):
            i += 3
            start = i
            while i < n and not src.startswith('"""', i):
                i += 2 if src[i] == "\\" else 1
            out.append(f"{STR_OPEN}{len(strings)}{STR_OPEN}")
            strings.append(src[start:i])
            i += 3
        elif c == '"':
            i += 1
            buf = []
            while i < n and src[i] != '"':
                if src[i] == "\\":
                    buf.append(src[i : i + 2])
                    i += 2
                else:
                    buf.append(src[i])
                    i += 1
            out.append(f"{STR_OPEN}{len(strings)}{STR_OPEN}")
            strings.append("".join(buf))
            i += 1
        elif c == "'":
            i += 1
            while i < n and src[i] != "'":
                i += 2 if src[i] == "\\" else 1
            i += 1
            out.append(" ")
        else:
            out.append(c)
            i += 1
    return "".join(out), strings


def lex_ts(src):
    """Strip TS comments; return (code, strings). ${...} becomes a MARK."""
    strings = []
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            while i < n and src[i] != "\n":
                i += 1
        elif src.startswith("/*", i):
            i += 2
            while i < n and not src.startswith("*/", i):
                i += 1
            i += 2
            out.append(" ")
        elif c in "\"'":
            quote, i = c, i + 1
            buf = []
            while i < n and src[i] != quote:
                if src[i] == "\\":
                    buf.append(src[i : i + 2])
                    i += 2
                else:
                    buf.append(src[i])
                    i += 1
            out.append(f"{STR_OPEN}{len(strings)}{STR_OPEN}")
            strings.append("".join(buf))
            i += 1
        elif c == "`":
            i += 1
            buf = []
            while i < n and src[i] != "`":
                if src[i] == "\\":
                    buf.append(src[i : i + 2])
                    i += 2
                elif src.startswith("${", i):
                    depth, i = 1, i + 2
                    while i < n and depth:
                        if src[i] == "{":
                            depth += 1
                        elif src[i] == "}":
                            depth -= 1
                        i += 1
                    buf.append(MARK)
                else:
                    buf.append(src[i])
                    i += 1
            out.append(f"{STR_OPEN}{len(strings)}{STR_OPEN}")
            strings.append("".join(buf))
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out), strings


def collapse(code):
    return re.sub(r"\s+", " ", code)


PLACEHOLDER = re.compile(rf"{STR_OPEN}(\d+){STR_OPEN}")


# --------------------------------------------------------------------------
# Routes
# --------------------------------------------------------------------------

SCOPE_RE = re.compile(r'^(\s*)scope\s+"([^"]*)"')
END_RE = re.compile(r"^(\s*)end\s*$")
VERB_RE = re.compile(
    r'^\s*(get|post|put|patch|delete|head|options)\s+"([^"]+)"\s*,\s*(\S+?)\s*,\s*:(\w+)'
)
RESOURCES_RE = re.compile(r'^\s*resources\s+"([^"]+)"\s*,\s*([A-Za-z0-9_.]+)\s*,?(.*)$')
RESOURCE_ACTIONS = {
    "index": ("get", ""),
    "show": ("get", "/:id"),
    "create": ("post", ""),
    "update": ("put", "/:id"),
    "delete": ("delete", "/:id"),
    "new": ("get", "/new"),
    "edit": ("get", "/:id/edit"),
}


def join_path(prefix, path):
    joined = (prefix.rstrip("/") + "/" + path.lstrip("/")).rstrip("/")
    return joined or "/"


def read_routes():
    routes = []
    stack = []  # (indent, prefix)
    with open(ROUTER, encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            scope = SCOPE_RE.match(line)
            if scope:
                indent, path = len(scope.group(1)), scope.group(2)
                parent = stack[-1][1] if stack else ""
                stack.append((indent, join_path(parent, path)))
                continue
            closing = END_RE.match(line)
            if closing and stack and len(closing.group(1)) == stack[-1][0]:
                stack.pop()
                continue
            if not stack:
                continue
            prefix = stack[-1][1]
            verb = VERB_RE.match(line)
            if verb:
                routes.append(
                    {
                        "method": verb.group(1).upper(),
                        "path": join_path(prefix, verb.group(2)),
                        "handler": f'{verb.group(3).rstrip(",")}.{verb.group(4)}',
                        "line": lineno,
                    }
                )
                continue
            res = RESOURCES_RE.match(line)
            if res:
                base, controller, rest = res.group(1), res.group(2).rstrip(","), res.group(3)
                only = re.search(r"only:\s*\[([^\]]*)\]", rest)
                names = (
                    [a.strip().lstrip(":") for a in only.group(1).split(",") if a.strip()]
                    if only
                    else list(RESOURCE_ACTIONS)
                )
                excepted = re.search(r"except:\s*\[([^\]]*)\]", rest)
                if excepted:
                    drop = {a.strip().lstrip(":") for a in excepted.group(1).split(",")}
                    names = [a for a in names if a not in drop]
                for action in names:
                    if action not in RESOURCE_ACTIONS:
                        continue
                    method, suffix = RESOURCE_ACTIONS[action]
                    routes.append(
                        {
                            "method": method.upper(),
                            "path": join_path(prefix, base + suffix),
                            "handler": f"{controller}.{action}",
                            "line": lineno,
                        }
                    )
    return [r for r in routes if r["path"] == "/api" or r["path"].startswith("/api/")]


def route_segments(path):
    """Router path -> list of (is_param, literal)."""
    segs = []
    for seg in path.strip("/").split("/"):
        if seg.startswith(":") or seg.startswith("*"):
            segs.append((True, None))
        else:
            segs.append((False, seg))
    return segs


# --------------------------------------------------------------------------
# Client call sites
# --------------------------------------------------------------------------


def normalise_call(raw):
    """Concatenated path -> glob segments, query/fragment dropped."""
    raw = raw.split("?")[0].split("#")[0]
    if not raw.startswith("/api"):
        return None
    segs = []
    for seg in raw.strip("/").split("/"):
        seg = re.sub(re.escape(MARK) + "+", "*", seg)
        segs.append(seg if seg else "*")
    return segs


def read_term(code, j):
    """Consume one Elm term at j; return (is_literal_index, end)."""
    n = len(code)
    if j < n and code[j] == STR_OPEN:
        match = PLACEHOLDER.match(code, j)
        if match:
            return int(match.group(1)), match.end()
    if j < n and code[j] in "([":
        depth, j = 1, j + 1
        while j < n and depth:
            if code[j] in "([":
                depth += 1
            elif code[j] in ")]":
                depth -= 1
            j += 1
        return None, j
    start = j
    while j < n and (code[j].isalnum() or code[j] in "._'"):
        j += 1
    return (None, j) if j > start else (None, -1)


def elm_calls(code, strings, path_label, sites):
    """Chase `"/api/..." ++ x ++ "/y"` chains and Url.Builder segment lists."""
    for match in PLACEHOLDER.finditer(code):
        value = strings[int(match.group(1))]
        if "/api" not in value:
            continue
        raw = value[value.index("/api") :]
        j = match.end()
        while True:
            while j < len(code) and code[j] == " ":
                j += 1
            if not code.startswith("++", j):
                break
            j += 2
            while j < len(code) and code[j] == " ":
                j += 1
            idx, end = read_term(code, j)
            if end == -1:
                break
            raw += strings[idx] if idx is not None else MARK
            j = end
        segs = normalise_call(raw)
        if segs:
            sites.append((segs, path_label))

    for match in re.finditer(r"Url\.Builder\.(?:absolute|crossOrigin|relative)", code):
        open_at = code.find("[", match.end())
        if open_at == -1:
            continue
        depth, j = 1, open_at + 1
        while j < len(code) and depth:
            if code[j] == "[":
                depth += 1
            elif code[j] == "]":
                depth -= 1
            j += 1
        parts = code[open_at + 1 : j - 1].split(",")
        raw = ""
        for part in parts:
            placed = PLACEHOLDER.search(part)
            raw += "/" + (strings[int(placed.group(1))] if placed else MARK)
        segs = normalise_call(raw)
        if segs:
            sites.append((segs, path_label))


REQUEST_CALL = re.compile(
    r"(?:^|[^A-Za-z0-9_$])(?:[A-Za-z0-9_$.]+\.)?"
    rf"(?:get|post|put|delete|patch|head|fetch|goto)\(\s*([A-Za-z0-9_$]+|{STR_OPEN}\d+{STR_OPEN})"
)
ASSIGNMENT = re.compile(rf"(?:const|let|var)\s+([A-Za-z0-9_$]+)\s*=\s*{STR_OPEN}(\d+){STR_OPEN}")
HELPER_CALL = re.compile(r"apiCallFromPage\(([^{]*)")


def ts_calls(code, strings, path_label, sites):
    """Only real request call sites count — a page.route() mock is not a caller."""
    by_var = {}
    for match in ASSIGNMENT.finditer(code):
        by_var[match.group(1)] = strings[int(match.group(2))]

    def record(value):
        if "/api" not in value:
            return
        segs = normalise_call(value[value.index("/api") :])
        if segs:
            sites.append((segs, path_label))

    for match in REQUEST_CALL.finditer(code):
        arg = match.group(1)
        placed = PLACEHOLDER.fullmatch(arg)
        if placed:
            record(strings[int(placed.group(1))])
        elif arg in by_var:
            record(by_var[arg])

    for match in HELPER_CALL.finditer(code):
        for placed in PLACEHOLDER.finditer(match.group(1)):
            record(strings[int(placed.group(1))])


def walk(root, suffix):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ("node_modules", "elm-stuff", ".git")]
        for name in sorted(filenames):
            if name.endswith(suffix):
                found.append(os.path.join(dirpath, name))
    return sorted(found)


IMPORT_RE = re.compile(r"^import\s+([A-Z][A-Za-z0-9_.]*)", re.MULTILINE)


def reachable_elm_modules(sources):
    """Modules the compiled app can actually reach, from Main outward.

    Elm has no dynamic import, so the import graph from the single entry point
    is the whole live program. A call site in a module nothing imports is dead
    code, and dead code is not a client — that is the shape the third-spaces
    page had when its route was first reported as caller-less.
    """
    imports = {}
    for module, path in sources.items():
        with open(path, encoding="utf-8") as handle:
            imports[module] = set(IMPORT_RE.findall(handle.read()))
    live, queue = set(), [ELM_ENTRY]
    while queue:
        module = queue.pop()
        if module in live or module not in imports:
            continue
        live.add(module)
        queue.extend(imports[module])
    return live


def read_call_sites():
    sites = []
    elm_sources = {}
    for path in walk(ELM_ROOT, ".elm"):
        module = os.path.relpath(path, ELM_ROOT)[: -len(".elm")].replace(os.sep, ".")
        elm_sources[module] = path
    live = reachable_elm_modules(elm_sources)
    dead = sorted(set(elm_sources) - live)
    for module in sorted(live):
        with open(elm_sources[module], encoding="utf-8") as handle:
            code, strings = lex_elm(handle.read())
        elm_calls(collapse(code), strings, elm_sources[module], sites)
    for root in TS_ROOTS:
        if not os.path.isdir(root):
            continue
        for path in walk(root, ".ts"):
            with open(path, encoding="utf-8") as handle:
                code, strings = lex_ts(handle.read())
            ts_calls(collapse(code), strings, path, sites)
    for root in JS_ROOTS:
        if not os.path.isdir(root):
            continue
        for path in walk(root, ".js"):
            with open(path, encoding="utf-8") as handle:
                code, strings = lex_ts(handle.read())
            ts_calls(collapse(code), strings, path, sites)
    return sites, dead


# --------------------------------------------------------------------------
# Matching
# --------------------------------------------------------------------------


def match_kind(route_segs, call_segs):
    """None, 'exact', or 'loose' — loose means a bare * stood in for a literal."""
    if len(route_segs) != len(call_segs):
        return None
    kind = "exact"
    # No zip(strict=): this runs under the system interpreter too, which is 3.9.
    # The length check above is what makes the pairing total.
    for (is_param, literal), glob in zip(route_segs, call_segs):
        if is_param:
            continue
        if not fnmatch.fnmatchcase(literal, glob):
            return None
        if glob == "*":
            kind = "loose"
    return kind


def read_allowlist():
    entries, malformed = [], []
    if not os.path.exists(ALLOWLIST):
        return entries, malformed
    with open(ALLOWLIST, encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            parts = stripped.split(None, 1)
            if len(parts) != 2:
                malformed.append((lineno, stripped, "no reason on the line"))
                continue
            path, reason = parts[0], parts[1].strip()
            tag = reason.split(":", 1)[0].strip()
            if tag not in REASON_TAGS or ":" not in reason or not reason.split(":", 1)[1].strip():
                why = f"reason must be '<tag>: <why>' with tag in {', '.join(REASON_TAGS)}"
                malformed.append((lineno, stripped, why))
                continue
            entries.append({"path": path, "reason": reason, "line": lineno})
    return entries, malformed


def main():
    routes = read_routes()
    sites, dead_modules = read_call_sites()
    allowed, malformed = read_allowlist()
    allowed_by_path = {}
    for entry in allowed:
        allowed_by_path.setdefault(entry["path"], []).append(entry)

    by_path = {}
    for route in routes:
        by_path.setdefault(route["path"], []).append(route)

    matched = {}
    for path in by_path:
        segs = route_segments(path)
        best = None
        for call_segs, label in sites:
            kind = match_kind(segs, call_segs)
            if kind == "exact":
                best = ("exact", label, "/" + "/".join(call_segs))
                break
            if kind == "loose" and best is None:
                best = ("loose", label, "/" + "/".join(call_segs))
        matched[path] = best

    unconsumed = sorted(p for p in by_path if matched[p] is None)
    unexplained = [p for p in unconsumed if p not in allowed_by_path]
    stale = [e for e in allowed if e["path"] not in by_path or matched.get(e["path"]) is not None]

    if MODE == "--report":
        print(f"== API routes ({len(by_path)} paths, {len(routes)} routes) ==")
        for path in sorted(by_path):
            verbs = ",".join(sorted({r["method"] for r in by_path[path]}))
            hit = matched[path]
            if hit:
                print(f"  {verbs:<8} {path:<52} {hit[0]} via {hit[1]}")
            elif path in allowed_by_path:
                reason = allowed_by_path[path][0]["reason"]
                print(f"  {verbs:<8} {path:<52} ALLOWLISTED {reason}")
            else:
                print(f"  {verbs:<8} {path:<52} NO CLIENT")
        print(f"\n== distinct client call sites ({len(sites)}) ==")
        for segs in sorted({"/" + "/".join(s) for s, _ in sites}):
            print("  " + segs)
        print(
            f"\n== Elm modules unreachable from {ELM_ENTRY}, "
            f"so not counted as clients ({len(dead_modules)}) =="
        )
        for module in dead_modules:
            print("  " + module)

    debt = [e for e in allowed if e["reason"].startswith(DEBT_TAG) and e["path"] in by_path]
    justified = len(unconsumed) - len(unexplained) - len(debt)
    print(
        f"\ncheck-route-clients: {len(by_path)} API route paths, {len(sites)} client call sites, "
        f"{len(unconsumed)} unconsumed ({justified} justified, "
        f"{len(debt)} recorded as known defects, {len(unexplained)} unexplained)."
    )

    failed = False
    if malformed:
        failed = True
        print(f"\nFAIL: {len(malformed)} malformed allowlist entr(ies) in {ALLOWLIST}:")
        for lineno, text, why in malformed:
            print(f"  {ALLOWLIST}:{lineno}: {text}  <- {why}")

    if unexplained:
        failed = True
        print(
            f"\nFAIL: {len(unexplained)} API route path(s) have no client call site "
            "and no allowlist entry:"
        )
        for path in unexplained:
            for route in by_path[path]:
                where = f"{ROUTER}:{route['line']}"
                print(f"  {route['method']:<6} {path:<52} {route['handler']} ({where})")
        print(
            f"\n  Either wire a client to it, or add a line to {ALLOWLIST}:\n"
            "      <path>    <tag>: <why it has no client>\n"
            f"  where <tag> is one of: {', '.join(REASON_TAGS)}\n"
            "  An endpoint nothing calls and nothing justifies is a defect, not a formality."
        )

    if stale:
        failed = True
        print(f"\nFAIL: {len(stale)} allowlist entr(ies) no longer apply — delete them:")
        for entry in stale:
            why = (
                "route no longer exists"
                if entry["path"] not in by_path
                else "route now has a client call site"
            )
            print(f"  {ALLOWLIST}:{entry['line']}: {entry['path']}  <- {why}")

    if debt:
        print(
            f"\nWARNING: {len(debt)} route path(s) are recorded as known defects "
            "— a client is missing,"
        )
        print("         not deliberately absent. These do not fail the build; they are debt:")
        for entry in sorted(debt, key=lambda e: e["path"]):
            print(f"  {entry['path']:<52} {entry['reason']}")

    if failed:
        return 1
    print("\nOK: every API route has a client call site or a recorded reason.")
    return 0


sys.exit(main())
PY
