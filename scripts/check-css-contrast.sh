#!/usr/bin/env bash
# ⛔ THE STYLESHEET HAD NO CONTRAST GATE, AND A 3.81:1 TEXT COLOUR SHIPPED.
#
# `--accent` was used as a body-text colour against `--bg` at 3.81:1 where WCAG
# AA asks 4.5:1. Nothing caught it: `check-css.sh` reads specificity and
# `check-css-values.sh` reads spacing tokens, and neither knows what a colour
# looks like. A ux reviewer found it by measuring the rendered page.
#
# ⚖️ This checks the TOKENS, not every rule. A token-level check is decidable
# from the stylesheet alone — `--accent-text` either clears AA against `--bg`
# or it does not — whereas a per-rule check needs the cascade resolved and the
# actual background of each element, which is a browser's job. So this catches
# the class of defect at its source: a colour promoted to text use that was
# never readable.
#
# ⚠️ So it is NOT a claim that every text/background pair on the site passes.
# It is a claim that the tokens INTENDED for text clear AA against the page
# background. A rule that paints text with a non-text token still slips
# through, which is why the token is named for its purpose.
set -uo pipefail
CSS="${1:-frontend/css/main.css}"

python3 - "$CSS" <<'PY'
import re, sys

css = open(sys.argv[1]).read()


def srgb(h):
    h = h.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    return [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]


def lum(h):
    c = [(v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4) for v in srgb(h)]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def ratio(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def token(name):
    m = re.search(r"--" + name + r":\s*(#[0-9a-fA-F]{3,6})\s*;", css)
    return m.group(1) if m else None


bg = token("bg")
if not bg:
    print("FAIL: no --bg token found; this gate cannot evaluate anything")
    sys.exit(1)

# Tokens whose NAME says they are for text. AA: 4.5 for body, 3.0 for large.
TEXT_TOKENS = {"text": 4.5, "text-muted": 4.5, "accent-text": 4.5}

bad = []
checked = 0
for name, need in TEXT_TOKENS.items():
    value = token(name)
    if value is None:
        continue
    checked += 1
    r = ratio(value, bg)
    if r < need:
        bad.append(f"  --{name} ({value}) on --bg ({bg}) is {r:.2f}:1, AA needs {need}:1")

# ⬛ ANTI-VACUITY: a renamed token would make every check above skip silently,
# and this gate would pass having evaluated nothing.
if checked == 0:
    print("FAIL: no text tokens matched — this gate evaluated nothing and must not pass")
    sys.exit(1)

if bad:
    print(f"FAIL: {len(bad)} text token(s) below WCAG AA against --bg:")
    print("\n".join(bad))
    sys.exit(1)

print(f"OK: {checked} text token(s) clear WCAG AA against --bg ({bg})")
PY
