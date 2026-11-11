#!/usr/bin/env bash
# Every script has a caller, and the inventory that says so is generated.
#
# scripts/ had grown to 93 files, of which six had NO caller anywhere — three
# were superseded twins of logic that had moved inline (a second deploy path is
# a drift machine), one duplicated an MCP capability, and the MCP server's own
# test suite had NEVER RUN: on its first execution, three tests failed, one
# because a repo-wide sweep had mutilated its fixtures and nothing noticed.
# "Exists in scripts/" said nothing about "runs anywhere".
#
# WHAT IT CHECKS  Every file under scripts/ is referenced by at least one
# caller (justfile, .github workflows/actions, hooks, another script, e2e,
# mix.exs, .mcp.json) or carries an ALLOWLIST entry naming why it is manual.
# It also regenerates scripts/README.md — the inventory of what calls what —
# and fails when the committed copy has drifted.
#
#   check-script-wiring.sh           # gate mode
#   check-script-wiring.sh --write   # regenerate scripts/README.md
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1
python3 - "${1:-check}" <<'PY'
import glob, os, re, sys

MODE = sys.argv[1].lstrip("-")

# Manual tools with no automated caller. Every entry carries its reason; a
# stale entry (the script gained a caller, or vanished) fails the gate.
ALLOWLIST = {
    "scripts/classify-credential-rewrite-equivalence.sh": (
        "Evidence over three fixed commits, not a gate. It classifies every credential "
        "rewrite in the one-builder migration against a table of equivalences; its corpus "
        "is historical and the question it answers can only be asked once, so wiring it "
        "into CI would re-run a settled measurement forever. ⚠️ The standing protection "
        "for the same property WAS check-credential-origin.sh, which is now deleted: "
        "every request in the client is a RequestSpec whose url is an "
        "Api.Url.SameOriginUrl, so the property that script parsed for is checked by the "
        "compiler on every build. frontend/tests/ApiRequestHeadersTest.elm still runs and "
        "covers the header half."
    ),
    "scripts/characterise/rowless-upload-objects.py": (
        "A one-off, READ-ONLY characterisation of the production bucket, kept as the "
        "record of how a deletion decision was measured rather than as a gate. It lists "
        "objects and compares them against uploaded_images rows; it calls list_objects_v2 "
        "and nothing else, so it cannot write or delete. Wiring it into CI would hit a "
        "production bucket on every run to re-answer a question that was already answered "
        "and acted on. The STANDING protection for the same property is "
        "ImageRetention.storage_consistency_check/0, which reports both populations as a "
        "metric on every sweep."
    ),
}

SKIP_DIRS = (".venv", "__pycache__")
scripts = sorted(
    p for p in glob.glob("scripts/**/*", recursive=True)
    if os.path.isfile(p)
    and not any(d in p for d in SKIP_DIRS)
    and os.path.basename(p) != "README.md"
    and not p.endswith((".pyc", ".txt", ".json"))
)

corpus = {}
for pat in ["justfile", ".github/workflows/*.yml", ".github/actions/**/*.yml",
            ".claude/settings.json", "scripts/**/*", "e2e/**/*.ts", "e2e/*.json",
            "mix.exs", "apps/core/mix.exs", ".mcp.json",
            # A gate's test fixture RUNS the gate, so it is a caller in the only
            # sense this gate measures — and leaving it out had a second-order
            # cost, not just an incomplete inventory. With fixtures invisible, a
            # script whose only exerciser is its own test read as an orphan, and
            # the pressure was then to name it somewhere the corpus can see,
            # which is how a bare mention in a DATA table starts standing in for
            # an invocation. Including them removes the incentive.
            "test/**/*.sh"]:
    for f in glob.glob(pat, recursive=True):
        # The generated inventory names every script — it is the OUTPUT of this
        # gate, never a caller, or the first --write makes everything "wired".
        if f == "scripts/README.md": continue
        if os.path.isfile(f) and not any(d in f for d in SKIP_DIRS):
            try: corpus[f] = open(f, encoding="utf-8", errors="ignore").read()
            except OSError: pass

# A mention in a COMMENT is not a call.
#
# This used to be a bare substring search over the whole file, so merely naming
# a script recorded the naming file as a caller: a comment explaining what a
# script replaces, a header listing what a gate supersedes, a note about a known
# failure. That inflated "called by" with files that invoke nothing — and worse
# in the other direction, a genuinely orphaned script could be lifted off the
# orphan list by one sentence of prose about it, which makes the gate's central
# claim ("a script with no caller cannot sit here silently") false.
#
# ⚠️ THE OBVIOUS STRONGER FIX DOES NOT WORK HERE, and it was tried and measured
# rather than reasoned about. Requiring the mention to LOOK like an invocation —
# the name following `bash`/`sh`/`source`/`python`/a workflow `run:`/a path
# separator — reported 11 live scripts as orphans, because this repo dispatches
# through its own shell functions: `lint-elm.sh` runs its gates as
# `gate check-css.sh`, and `install-hooks.sh` installs via
# `install_hook "pre-commit"`. Neither is distinguishable from prose by shape,
# and enumerating every project-local dispatcher is a list that goes stale
# exactly when someone adds a dispatcher.
#
# So the rule is the narrower one that the evidence supports: strip comments,
# keep everything else. The comment test is deliberately crude — it drops only
# lines whose first non-space characters begin a comment — because the
# alternative is parsing four languages, and a commented-out invocation is not
# an invocation either.
def _code_lines(txt, path=""):
    out = []
    for line in txt.split("\n"):
        stripped = line.lstrip()
        # `#` covers shell, python and yaml; `//` and `*` cover JS/TS and block
        # comments; `|` covers a markdown table row, which is the shape of this
        # gate's own generated inventory.
        if stripped.startswith(("#", "//", "*", "|")):
            continue
        # ⛔ A LINE THAT IS ONLY A QUOTED STRING IS DATA, NOT A CALL.
        #
        # Comment-stripping closes the prose route and leaves the data route
        # open: an exemption list, a fixture pairing, an assertion description
        # or a generated-file banner names a script on a line of code, and the
        # caller search counts it. MEASURED on this repository, three live
        # false callers of exactly this shape:
        #
        #   check-sigpipe-hazards.sh's FIXTURE_FILES entries  -> check-rls-scope.sh
        #   gen-elm-proto.py's "Regenerate via …" banner      -> gen-elm-proto.sh
        #   rollback_action_composite_test.sh's assertion text -> rollback-production.sh
        #
        # None of those files invokes the script it was recorded as calling.
        #
        # ⚠️ The first example is kept as the MEASUREMENT it was, but the
        # construct is gone: `check-sigpipe-hazards.sh` no longer has a
        # `FIXTURE_FILES` list, having replaced its whole-file exemptions with a
        # data/code classifier. Don't go looking for it. The shape it
        # illustrates is still live, which is why the rule stays.
        #
        # ⚠️ This is NOT the stricter fix the comment above refutes. That one
        # asked what an invocation looks like and reported 11 live scripts as
        # orphans, because this repo dispatches through its own shell functions.
        # This asks what DATA looks like, which is a much narrower question: a
        # bare string literal on its own line is never how anything here runs a
        # script. The stated limit is that a longer data string with code around
        # it stays unclassifiable.
        #
        # ⛔ GATED ON EXTENSION, and the condition is not caution — it is the
        # difference between imperative and declarative source. In a shell or
        # Python file a bare string literal on its own line is never how
        # anything runs a script. In a declarative config a quoted string IS
        # the invocation: `.claude/settings.json` wires the Stop hook as
        # `"command": "…/pre-stop-lint.sh"`, and a config that listed commands
        # one per line would put a bare quoted path there legitimately.
        #
        # MEASURED both ways. The ungated rule does NOT in fact strip that
        # settings.json line — it carries a key prefix and internal escaped
        # quotes, so `[^'"]*` cannot span it, and `pre-stop-lint.sh` keeps its
        # caller either way. But `"scripts/foo.sh"` alone on a line IS stripped
        # by it, and in declarative config that would be a real invocation
        # discarded. There are ZERO such lines in the declarative corpus today,
        # which is the cheapest moment to close it rather than the moment it
        # manufactures an orphan.
        if path.endswith((".sh", ".py")) and re.fullmatch(r"""(['"])[^'"]*\1,?""", stripped):
            continue
        # ⛔ A MAPPING KEY IS DATA TOO, and this gate's own ALLOWLIST is the
        # proof — the rule above only covers a BARE string literal.
        #
        # MEASURED 2026-10-27, the first time anything was ever put in the
        # ALLOWLIST: `"scripts/x.sh": (` is a quoted string followed by `: (`,
        # so the rule above does not strip it, so the entry counted as a CALLER
        # of the script it exempts, so the entry was immediately reported
        # stale — "gained a caller". **The allowlist was unusable, and nobody
        # knew because it had been empty since the gate was written.** An
        # escape hatch with no entries is an escape hatch nobody has tried.
        #
        # ⚠️ The shape generalises past this gate: any exemption map, fixture
        # pairing or routing table in a `.sh`/`.py` file keyed BY SCRIPT PATH
        # has exactly this form, and each one would manufacture a false caller
        # for the script it names.
        if path.endswith((".sh", ".py")) and re.fullmatch(
            r"""(['"])[^'"]*\1\s*:\s*(?:[(\[{]|(['"])[^'"]*\2)?,?""", stripped
        ):
            continue
        out.append(line)
    return out


def callers(path):
    base = os.path.basename(path)
    # Python modules are imported by stem, not filename.
    needles = {base}
    if base.endswith(".py"):
        needles.add(base[:-3])
    found = []
    for f, txt in corpus.items():
        if f == path:
            continue
        code = "\n".join(_code_lines(txt, f))
        if any(n in code for n in needles):
            found.append(f)
    return sorted(found)

def purpose(path):
    try: lines = open(path, encoding="utf-8", errors="ignore").read().split("\n")
    except OSError: return ""
    for ln in lines[:12]:
        s = ln.strip()
        if s.startswith("#!") or not s: continue
        if s.startswith("#"): return s.lstrip("# ").strip()
        m = re.match(r'^\s*"""(.+?)("""|$)', ln)
        if m: return m.group(1).strip()
        break
    return ""

rows, orphans = [], []
for p in scripts:
    c = callers(p)
    if not c and p not in ALLOWLIST:
        orphans.append(p)
    rows.append((p, c, ALLOWLIST.get(p)))

stale = sorted(k for k in ALLOWLIST if k not in scripts or callers(k))

def render():
    out = ["# scripts/ — generated inventory",
           "",
           "<!-- GENERATED by check-script-wiring.sh --write — do not edit by hand. -->",
           "",
           "Every script here is either invoked by the listed callers or allowlisted as",
           "a manual tool with a reason. The wiring gate regenerates this file and fails",
           "on drift, so a script with no caller cannot sit here silently.",
           "",
           "**What \"called by\" measures.** A caller is a file that names this script on a",
           "line of code — comments are stripped, and in a `.sh` or `.py` source a line that",
           "is only a quoted string is treated as data rather than an invocation (an",
           "exemption list, a fixture pairing, a generated-file banner). That is deliberately",
           "narrower than asking what an invocation *looks like*, which reported 11 live",
           "scripts as orphans here because this repo dispatches through its own shell",
           "functions. The residue: a script named inside a longer data string, with code",
           "around it, still counts as called. So read a single surprising caller as \"named",
           "in code by\" and check it before relying on it.",
           "",
           "| script | called by | purpose |",
           "|---|---|---|"]
    for p, c, allow in rows:
        if allow: who = f"_manual: {allow}_"
        elif c:   who = ", ".join(f"`{x}`" for x in c[:4]) + (" …" if len(c) > 4 else "")
        else:     who = "⚠️ none"
        out.append(f"| `{p}` | {who} | {purpose(p)[:96]} |")
    return "\n".join(out) + "\n"

if MODE == "write":
    open("scripts/README.md", "w").write(render())
    print(f"scripts/README.md written — {len(rows)} script(s)")
    sys.exit(0)

failed = False
if orphans:
    failed = True
    print(f"FAIL: {len(orphans)} script(s) with NO caller and no allowlist reason:", file=sys.stderr)
    for p in orphans: print(f"  {p}", file=sys.stderr)
    print("\nWire it, delete it, or allowlist it with the reason it is manual.", file=sys.stderr)
if stale:
    failed = True
    print(f"FAIL: {len(stale)} stale ALLOWLIST entr(y/ies) — gained a caller or vanished:", file=sys.stderr)
    for p in stale: print(f"  {p}", file=sys.stderr)
try: committed = open("scripts/README.md", encoding="utf-8").read()
except OSError: committed = None
if committed != render():
    failed = True
    print("FAIL: scripts/README.md is stale — run scripts/check-script-wiring.sh --write", file=sys.stderr)
if not failed:
    print(f"OK: {len(rows)} script(s) all wired or allowlisted; inventory current.")
sys.exit(1 if failed else 0)
PY
