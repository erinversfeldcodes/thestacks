#!/usr/bin/env bash
# check-css-values.sh — the THIRD CSS gate: it governs token VALUES (Wave 9 / #319).
#
# WHY THIS EXISTS
#
# The two structural gates that preceded this one both sit at a zero floor:
#   - check-orphan-classes.sh  — markup naming a class with no rule (the DOM lies).
#   - check-css.sh             — well-formedness, specificity traps, cascade order.
# Neither looks at the VALUES in a declaration. So the file could — and did — accumulate 272 hardcoded
# hex literals and 516 raw spacing literals while a green `just verify` said nothing, because a literal
# `#a09070` and `var(--text-muted)` render identically: the drift is invisible to a browser and to
# every test, and only shows up as a second error-red or a fourth almost-parchment months later.
#
# Wave 9 built the token system (scales + semantic state tokens) and migrated the exact-duplicate
# hexes. This gate stops the file drifting back: once a value has a token name, a bare literal equal to
# that value is a bug — it should have been the token.
#
# WHAT IT CHECKS (four dimensions, each an independent ratchet)
#
#   1. LITERAL == A TOKEN'S VALUE.  A bare hex in a *rule declaration* whose value exactly equals a
#      defined token's value — e.g. `color: #a09070` when `--text-muted: #a09070` exists. This is the
#      core anti-drift check: the literal should have been `var(--text-muted)`.
#         ⚠️ EXCLUSION: a literal that IS the value of a custom-property declaration (`--x: #a09070`)
#         is NOT flagged — that is a token *definition*, which is exactly where literals belong. The
#         exclusion is by declaration KIND (property starts with `--`), so it covers :root, every
#         shelf-theme block, the page-scoped parchment block, and any inline `--foo:` alike, without
#         hard-coding a list of "token blocks". Literals inside a `var(… , <fallback>)` are also
#         excluded here and judged only by check 3, so a value is never double-counted.
#
#   2. var() OF AN UNDEFINED TOKEN.  `var(--never-defined)` — a phantom var. Resolves to nothing (or to
#      its fallback if it has one), and a typo'd token name is otherwise silent.
#
#   3. A FALLBACK THAT DISAGREES WITH THE DEFINITION.  `var(--x, <lit>)` where `<lit>` is not any
#      defined value of `--x`. The fallback is a lie: if --x ever fails to resolve, the surface renders
#      a colour/size the token was never meant to be. A fallback that is itself a `var()` (a var-chain,
#      `var(--a, var(--b))`) is legitimate and skipped here — its inner name is still checked by 2.
#
#   4. NEW SPACING LITERAL == A --space-* VALUE.  A margin/padding/gap literal (rem) exactly equal to a
#      spacing-scale step but written as a raw literal instead of the token. Spacing has ZERO adoption
#      today (greenfield), so this dimension starts as a large ratchet, NOT a floor — the budget is the
#      current count and ratchets toward zero as surfaces migrate.
#
# RATCHET DISCIPLINE (mirrors the orphan gate + check-css.sh)
#
# Each dimension has an explicit budget = its CURRENT count, so the gate is green today. A NEW
# violation beyond the budget fails the build. The colour/var/fallback residuals below are the cases
# Wave 9's migration (9b) deliberately LEFT because migrating them would change pixels — theme-varying
# bare hexes that map to different token names per theme, near-duplicate fallbacks, and one phantom var
# with a safe fallback. Each is itemised so the budget is a shrinking ledger, not a silent allowance.
#
# Usage:
#   scripts/check-css-values.sh            # gate
#   scripts/check-css-values.sh --list     # every finding in every dimension
#   scripts/check-css-values.sh --update   # print the budget lines to paste when a dimension drops
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1
MODE="${1:-check}"

# ---- Budgets: current count per dimension. Lower as migrations land; never raise. ----
#
# COLOUR — 18 bare hexes each equal to a THEME-VARYING token's value, so they cannot be replaced by a
#   single var() without changing pixels in some theme (the token resolves to a DIFFERENT value in
#   another shelf/parchment context). 9b left them on purpose:
#     #1a1208 ×1  → --bg (default only)          · theme-varying (--bg is 5 different values)
#     #2c1f0e ×8  → --text / --parchment-text     · theme-varying (light themes + parchment)
#     #2c3e55 ×1  → --shelf-bg (wishlist)          · theme-varying; the #319 bake-in cautionary case
#     #3d2b1f ×4  → --shelf-bg (library/pile)      · theme-varying
#     #4a7c59 ×2  → --accent / --success / parch   · one value, three token names (ambiguous target)
#     #d4dde8 ×1  → --text (wishlist)              · theme-varying
#     #e8dcc8 ×1  → --text / --parchment-dark      · theme-varying + ambiguous
COLOUR_LITERAL_BUDGET=18

# UNDEFINED VAR — 1 phantom, with a safe fallback, so it renders correctly today:
#     var(--font-display, var(--font-body))  in .upload-inbox__heading
#       — --font-display is never defined; the intent was a display-font hook. Ratchet: either define
#         --font-display or drop it to var(--font-body).
UNDEFINED_VAR_BUDGET=1

# FALLBACK MISMATCH — fallbacks that disagree with the token definition. All pre-date the gate:
#     --parchment      fallback #f4ecd8   (app-nav__badge)        · near-dup of #f5efe0
#     --parchment-border fallback #c4b69c (×N book-detail/catalogue) · renders out-of-scope: an opaque
#         cream where the token is a translucent brown; a real near-dup left by 9b as a pixel change.
#     --radius-sm      fallback 0.25rem   (catalogue__filter-btn) · 0.25rem(4px) vs the token's 2px.
FALLBACK_MISMATCH_BUDGET=7

# SPACING — greenfield. Spacing tokens have ZERO adoption, so every margin/padding/gap literal that
#   happens to equal a --space-* step is a ratchet entry, not a floor. Migrate surfaces to shrink it.
SPACING_LITERAL_BUDGET=403

python3 - "$MODE" "$COLOUR_LITERAL_BUDGET" "$UNDEFINED_VAR_BUDGET" "$FALLBACK_MISMATCH_BUDGET" "$SPACING_LITERAL_BUDGET" <<'PY'
import re, sys
from collections import defaultdict

mode = sys.argv[1]
COLOUR_BUDGET   = int(sys.argv[2])
UNDEF_BUDGET    = int(sys.argv[3])
FALLBACK_BUDGET = int(sys.argv[4])
SPACING_BUDGET  = int(sys.argv[5])

path = "frontend/css/main.css"
raw = open(path, encoding="utf-8").read()
css = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)   # strip comments so their examples never count


def norm(v):
    return re.sub(r"\s+", " ", v).strip().lower()


# ---- Parse every rule body (head, body), nesting-aware ----------------------
def parse(text):
    out, i, buf = [], 0, ""
    while i < len(text):
        c = text[i]
        if c == "{":
            head, buf = buf.strip(), ""
            j, d = i + 1, 1
            while j < len(text) and d:
                if text[j] == "{":
                    d += 1
                elif text[j] == "}":
                    d -= 1
                j += 1
            out.append((head, text[i + 1 : j - 1]))
            i, buf = j, ""
        elif c == "}":
            buf, i = "", i + 1
        else:
            buf += c
            i += 1
    return out


rules = parse(css)


def declarations(body):
    """(property, raw_value) for the rule's OWN declarations — nested rules stripped first."""
    flat = re.sub(r"\{[^{}]*\}", "", body)
    for decl in flat.split(";"):
        if ":" not in decl:
            continue
        k, _, v = decl.partition(":")
        yield k.strip(), v.strip()


# ---- Build the value → token(s) map from every custom-property definition ---
token_values = defaultdict(set)   # token name -> {normalised values}
value_tokens = defaultdict(set)   # normalised value -> {token names}
for head, body in rules:
    for prop, val in declarations(body):
        if prop.startswith("--"):
            token_values[prop].add(norm(val))
            value_tokens[norm(val)].add(prop)

defined_tokens = set(token_values)
space_values = {next(iter(token_values[t])) for t in token_values if t.startswith("--space-")}


# ---- var() helpers: balanced-paren aware ------------------------------------
def find_var_calls(s):
    """Yield (name, fallback_or_None) for each TOP-LEVEL var() in s, parens balanced."""
    for m in re.finditer(r"var\(", s):
        start = m.end()  # just past '('
        depth, k = 1, start
        while k < len(s) and depth:
            if s[k] == "(":
                depth += 1
            elif s[k] == ")":
                depth -= 1
            k += 1
        inner = s[start : k - 1]
        # split on the FIRST top-level comma
        d, comma = 0, -1
        for idx, ch in enumerate(inner):
            if ch == "(":
                d += 1
            elif ch == ")":
                d -= 1
            elif ch == "," and d == 0:
                comma = idx
                break
        if comma == -1:
            yield inner.strip(), None
        else:
            yield inner[:comma].strip(), inner[comma + 1 :].strip()


def strip_var_calls(s):
    """Remove all var(...) spans (balanced) so their fallback literals are not colour-scanned."""
    out, i = "", 0
    while i < len(s):
        if s.startswith("var(", i):
            depth, k = 1, i + 4
            while k < len(s) and depth:
                if s[k] == "(":
                    depth += 1
                elif s[k] == ")":
                    depth -= 1
                k += 1
            i = k
        else:
            out += s[i]
            i += 1
    return out


HEX = re.compile(r"#[0-9a-fA-F]{3,8}\b")
LEN = re.compile(r"\d*\.?\d+(?:rem|px)\b")
SPACE_PROP = re.compile(r"^(margin|padding|gap|row-gap|column-gap)(-(top|right|bottom|left))?$")

colour_hits, undefined_vars, fallback_mismatch, spacing_hits = [], [], [], []

for head, body in rules:
    for prop, val in declarations(body):
        low = prop.lower()

        # 2 + 3: var() checks apply everywhere (including inside token defs — a phantom is a phantom).
        for name, fb in find_var_calls(val):
            if name and name not in defined_tokens:
                undefined_vars.append((head, name, f"{prop}: {val}"))
            elif fb is not None and "var(" not in fb:
                fbn = norm(fb)
                if fbn and fbn not in token_values.get(name, set()):
                    fallback_mismatch.append(
                        (head, name, fbn, sorted(token_values.get(name, set())), f"{prop}: {val}")
                    )

        # A custom-property declaration is a token DEFINITION — its literal value is correct there.
        if low.startswith("--"):
            continue

        # 1: bare hex (outside any var()) equal to a token's value.
        for hx in HEX.findall(strip_var_calls(val)):
            if norm(hx) in value_tokens:
                colour_hits.append((head, norm(hx), sorted(value_tokens[norm(hx)]), f"{prop}: {val}"))

        # 4: spacing literal equal to a --space-* step, in a spacing property.
        if SPACE_PROP.match(low):
            for m in LEN.finditer(strip_var_calls(val)):
                if m.group(0) in space_values:
                    spacing_hits.append((head, m.group(0), f"{prop}: {val}"))

counts = {
    "colour": (len(colour_hits), COLOUR_BUDGET),
    "undefined-var": (len(undefined_vars), UNDEF_BUDGET),
    "fallback-mismatch": (len(fallback_mismatch), FALLBACK_BUDGET),
    "spacing": (len(spacing_hits), SPACING_BUDGET),
}

if mode == "--update":
    print(f"COLOUR_LITERAL_BUDGET={len(colour_hits)}")
    print(f"UNDEFINED_VAR_BUDGET={len(undefined_vars)}")
    print(f"FALLBACK_MISMATCH_BUDGET={len(fallback_mismatch)}")
    print(f"SPACING_LITERAL_BUDGET={len(spacing_hits)}")
    sys.exit(0)

if mode == "--list":
    print(f"COLOUR literal==token value ({len(colour_hits)}):")
    for head, v, toks, decl in colour_hits:
        print(f"  {v}  {toks}  in `{head[:50]}`  ::  {decl[:60]}")
    print(f"\nUNDEFINED var() ({len(undefined_vars)}):")
    for head, name, decl in undefined_vars:
        print(f"  {name}  in `{head[:50]}`  ::  {decl[:60]}")
    print(f"\nFALLBACK mismatch ({len(fallback_mismatch)}):")
    for head, name, fb, defs, decl in fallback_mismatch:
        print(f"  {name} fallback `{fb}` not in {defs}  in `{head[:50]}`")
    print(f"\nSPACING literal==--space-* ({len(spacing_hits)}):")
    by_val = defaultdict(int)
    for head, v, decl in spacing_hits:
        by_val[v] += 1
    for v in sorted(by_val):
        print(f"  {v}  ×{by_val[v]}")
    sys.exit(0)

print("CSS values:  " + "   ".join(f"{k} {c}/{b}" for k, (c, b) in counts.items()))

failed = False


def report(label, hits, budget, fmt, fix):
    global failed
    n = len(hits)
    if n > budget:
        print(f"\n{n - budget} NEW {label} violation(s) (count {n} > budget {budget}):\n")
        for h in hits:
            print(f"  {fmt(h)}")
        print(f"\n{fix}")
        failed = True
    elif n < budget:
        print(f"\n{label}: {budget - n} BELOW budget ({n} < {budget}). Lower the budget:")
        print("  scripts/check-css-values.sh --update")


report(
    "colour-literal",
    colour_hits,
    COLOUR_BUDGET,
    lambda h: f"{h[1]} == token {h[2]}  in `{h[0][:50]}`  ({h[3][:50]})",
    "A bare hex equal to a token's value should be var(--that-token). If it is a theme-varying "
    "value that cannot be a single token, it belongs in the itemised budget with a reason.",
)
report(
    "undefined-var",
    undefined_vars,
    UNDEF_BUDGET,
    lambda h: f"var({h[1]}) is never defined  in `{h[0][:50]}`  ({h[2][:50]})",
    "Define the token, or fix the typo. A var() of an undefined name resolves to nothing.",
)
report(
    "fallback-mismatch",
    fallback_mismatch,
    FALLBACK_BUDGET,
    lambda h: f"var({h[1]}, {h[2]}) — fallback not in {h[3]}  in `{h[0][:50]}`",
    "The fallback must equal one of the token's defined values, or it renders a lie when the token "
    "fails to resolve.",
)
report(
    "spacing-literal",
    spacing_hits,
    SPACING_BUDGET,
    lambda h: f"{h[1]} == a --space-* step  in `{h[0][:50]}`  ({h[2][:50]})",
    "Use the --space-* token for this margin/padding/gap value.",
)

sys.exit(1 if failed else 0)
PY
