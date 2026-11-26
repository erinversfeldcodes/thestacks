#!/usr/bin/env bash
# ⛔ THE STYLESHEET HAD NO CONTRAST GATE, AND A 3.81:1 TEXT COLOUR SHIPPED.
#
# `--accent` was used as a body-text colour against `--bg` at 3.81:1 where WCAG
# AA asks 4.5:1. Nothing caught it: `check-css.sh` reads specificity and
# `check-css-values.sh` reads spacing tokens, and neither knows what a colour
# looks like. A ux reviewer found it by measuring the rendered page.
#
# ⚖️ This checks the TOKENS, not every rule. A token-level check is decidable
# from the stylesheet alone — `--accent-text` either clears AA against the page
# background or it does not — whereas a per-element check needs the cascade
# resolved and the actual background of each node, which is a browser's job.
#
# ⛔ EVERY PALETTE, NOT JUST `:root`. `main.css` redefines `--bg`/`--text` in
# five scopes (`:root` and four `.shelf-*` palettes). An earlier version read
# `--bg` with `re.search`, which returns the FIRST definition only, and reported
# "3 text tokens clear AA against --bg (#1a1208)" as though that were complete —
# while the two LIGHT shelf palettes left `--text-muted`/`--accent-text`
# inheriting the dark `:root` values and rendered them at 2.68–2.76:1. So this
# evaluates each text token against EACH palette's own `--bg`, resolving the
# cascade: a token a palette does not redefine takes its `:root` value there.
#
# ⛔ AND DECLARED SURFACE PAIRS. A `--warning-text` on `--warning` banner shipped
# at 2.65:1 because the token system had no VETTED surface pair and the author
# reached for the semantically-obvious one. A surface pair declares its intent
# in its name — `--X-surface` carries `--X-on-surface` — so this checks the
# `on-surface` colour against its surface for every such pair.
set -uo pipefail
CSS="${1:-frontend/css/main.css}"

python3 - "$CSS" <<'PY'
import re
import sys

css = open(sys.argv[1]).read()

# Anti-vacuity floors. A parse that finds fewer palettes than exist, or no
# surface pair, has drifted from the stylesheet and must refuse rather than pass
# over what it did not read.
MIN_PALETTES = 5
MIN_SURFACE_PAIRS = 1


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


def tokens_in(body):
    return dict(re.findall(r"--([a-z0-9-]+):\s*(#[0-9a-fA-F]{3,6})\s*;", body))


# Every `selector { body }` block. A block that defines `--bg` is a palette.
blocks = re.findall(r"([^{}]+)\{([^{}]*)\}", css, re.S)
root = {}
palettes = []  # (selector, own-tokens)
for sel, body in blocks:
    toks = tokens_in(body)
    sel = sel.strip().replace("\n", " ")
    if sel == ":root":
        root.update(toks)
    if "bg" in toks:
        palettes.append((sel, toks))

if len(palettes) < MIN_PALETTES:
    print(
        f"FAIL: found {len(palettes)} palette(s) defining --bg; floor is {MIN_PALETTES}. "
        "The parser has drifted from the stylesheet — refusing rather than passing over it."
    )
    sys.exit(1)

# Tokens whose NAME says they are for text. AA: 4.5 for body text.
TEXT_TOKENS = ("text", "text-muted", "accent-text")

bad = []
checked = 0
for sel, own in palettes:
    bg = own.get("bg")
    if not bg:
        continue
    # Cascade: a palette inherits :root's value for any token it does not
    # redefine. (`:root`'s own `own` IS root, so this is a no-op there.)
    eff = {**root, **own}
    for tok in TEXT_TOKENS:
        value = eff.get(tok)
        if value is None:
            continue
        checked += 1
        r = ratio(value, bg)
        if r < 4.5:
            bad.append(
                f"  {sel}: --{tok} ({value}) on --bg ({bg}) is {r:.2f}:1, AA needs 4.5:1"
            )

# Declared surface pairs: `--X-on-surface` must clear AA against `--X-surface`.
surface_pairs = 0
for name, on_val in re.findall(r"--([a-z0-9-]+)-on-surface:\s*(#[0-9a-fA-F]{3,6})\s*;", css):
    m = re.search(r"--" + re.escape(name) + r"-surface:\s*(#[0-9a-fA-F]{3,6})\s*;", css)
    if not m:
        continue
    surface_pairs += 1
    r = ratio(on_val, m.group(1))
    if r < 4.5:
        bad.append(
            f"  --{name}-on-surface ({on_val}) on --{name}-surface ({m.group(1)}) "
            f"is {r:.2f}:1, AA needs 4.5:1"
        )

# ⬛ ANTI-VACUITY: a renamed token or a broken parse would make the loops above
# skip silently, and this gate would pass having evaluated nothing.
if checked == 0:
    print("FAIL: no text tokens matched in any palette — this gate evaluated nothing.")
    sys.exit(1)
if surface_pairs < MIN_SURFACE_PAIRS:
    print(
        f"FAIL: found {surface_pairs} declared surface pair(s); floor is {MIN_SURFACE_PAIRS}. "
        "The `--X-surface`/`--X-on-surface` convention is gone or renamed — refusing."
    )
    sys.exit(1)

if bad:
    print(f"FAIL: {len(bad)} colour pair(s) below WCAG AA:")
    print("\n".join(bad))
    sys.exit(1)

print(
    f"OK: {checked} text-token/background pair(s) across {len(palettes)} palette(s) and "
    f"{surface_pairs} declared surface pair(s) clear WCAG AA."
)
PY
