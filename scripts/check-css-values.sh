#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1
MODE="${1:-check}"

COLOUR_LITERAL_BUDGET=18

UNDEFINED_VAR_BUDGET=1

FALLBACK_MISMATCH_BUDGET=7

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

token_values = defaultdict(set)   # token name -> {normalised values}
value_tokens = defaultdict(set)   # normalised value -> {token names}
for head, body in rules:
    for prop, val in declarations(body):
        if prop.startswith("--"):
            token_values[prop].add(norm(val))
            value_tokens[norm(val)].add(prop)

defined_tokens = set(token_values)
space_values = {next(iter(token_values[t])) for t in token_values if t.startswith("--space-")}

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

        for name, fb in find_var_calls(val):
            if name and name not in defined_tokens:
                undefined_vars.append((head, name, f"{prop}: {val}"))
            elif fb is not None and "var(" not in fb:
                fbn = norm(fb)
                if fbn and fbn not in token_values.get(name, set()):
                    fallback_mismatch.append(
                        (head, name, fbn, sorted(token_values.get(name, set())), f"{prop}: {val}")
                    )

        if low.startswith("--"):
            continue

        for hx in HEX.findall(strip_var_calls(val)):
            if norm(hx) in value_tokens:
                colour_hits.append((head, norm(hx), sorted(value_tokens[norm(hx)]), f"{prop}: {val}"))

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
