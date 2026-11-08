#!/usr/bin/env bash
#
# ⛔ A MODULE THAT BUILDS A REQUEST PLAN AND PERFORMS IT ITSELF IS INVISIBLE TO
# THE TEST HARNESS, AND THE ABSTRACTION'S CENTRAL CLAIM DOES NOT HOLD FOR IT.
#
# `Effect`'s opening paragraph says a page that returns its effects as data has
# exactly one decision and the harness reads it rather than guessing it.
# `TestHelpers.simulateEffect` can only read an `Effect` that ESCAPES the module
# — so where `Effect.perform` is called inside `update`, the plan is exactly as
# opaque as the raw `Http.request` it replaced, and no `ProgramTest` can assert
# what the page sends.
#
# ⚠️ MEASURED when this gate was written, and the first measurement was WRONG
# in a way worth recording: counting a `*WithEffect` that merely EXISTS said 17
# of 42 modules were covered. Counting only those that EXPORT it — the property
# that decides whether a harness can reach the plan — says **11 of 42**, with 31
# seamless holding 93 `Effect.perform` sites. A seam the module keeps to itself
# is unreachable, so the looser count credited progress no test could use. And the
# three modules that gained the most plans in the migration were the top three
# without a seam. The migration was 40% of an architecture, and nothing in the
# code said so.
#
# ⚖️ THIS IS A RATCHET, NOT A FLOOR, and the direction matters. The count may
# only fall. That lets the conversion land in batches without the boundary ever
# moving backwards, and it means a NEW module written the old way fails
# immediately rather than joining a crowd.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# ⛔ RATCHET. Lower this as modules gain their seam; never raise it. Raising it
# is how a temporary exception becomes the convention.
MAX_SEAMLESS=26

# ⛔ CONSERVED, NOT RATCHETED. A genuine conversion moves a module between
# buckets and changes NEITHER of these. A module that vanishes from the corpus —
# an aliased import, a rename, a deletion — shrinks the population; sites that
# grow inside an already-seamed module raise the site count. Both would
# otherwise look like progress, or like nothing at all.
EXPECTED_POPULATION=42
MAX_TOTAL_SITES=90

mode="${1:-}"

python3 - "$mode" "$MAX_SEAMLESS" "$EXPECTED_POPULATION" "$MAX_TOTAL_SITES" <<'PY'
import glob
import re
import sys

mode, max_seamless = sys.argv[1], int(sys.argv[2])
expected_population, max_total_sites = int(sys.argv[3]), int(sys.argv[4])

# ⚠️ Comments are blanked before anything is counted. An absence-style check
# that reads its own prose is a recurring defect in this repository: a module
# explaining why it has no seam would otherwise read as having one.
# ⛔ DEPTH-COUNTED, LIFTED FROM `check-http-timeouts.sh` RATHER THAN WRITTEN A
# THIRD TIME. Elm block comments NEST, so a flat non-greedy `{- … -}` terminates
# at the first inner `-}` and leaves residue behind. Both siblings `lint-elm.sh`
# runs already do this properly; a third hand-rolled variant is how the three
# drift apart.
#
# ⚖️ Blanks rather than deletes, so line numbers survive — the convention those
# siblings state, kept here even though this gate currently prints only paths.
def strip_comments(text):
    """Replace every comment's contents with spaces, preserving line structure.

    Prose describing a rule is not an instance of breaking it: the doc comment on
    `Page.CostTransparency.fetchCosts` explains why it is `Http.request` and not `Http.get`,
    and a naive scan read that sentence as a finding. Line numbers are preserved so the
    report still points at real source lines.
    """
    out, index, depth = [], 0, 0
    while index < len(text):
        two = text[index : index + 2]
        if depth == 0 and two == "--":
            end = text.find("\n", index)
            end = len(text) if end == -1 else end
            out.append(" " * (end - index))
            index = end
        elif two == "{-":
            depth += 1
            out.append("  ")
            index += 2
        elif two == "-}" and depth > 0:
            depth -= 1
            out.append("  ")
            index += 2
        else:
            out.append(text[index] if (depth == 0 or text[index] == "\n") else " ")
            index += 1
    return "".join(out)



seamless, seamed, half_converted, total_sites = [], [], [], 0

for path in sorted(
    glob.glob("frontend/src/Page/**/*.elm", recursive=True)
    + glob.glob("frontend/src/Components/**/*.elm", recursive=True)
):
    with open(path, encoding="utf-8") as handle:
        code = strip_comments(handle.read())

    performs = len(re.findall(r"\bEffect\.perform\b", code))

    # ⛔ AN ALIASED IMPORT MUST NOT MAKE A MODULE VANISH. `import Effect as Fx`
    # turns every `Effect.perform` into `Fx.perform`, and the population silently
    # shrinks — which the below-ratchet branch then reads as ground gained.
    # MEASURED by the platform review: aliasing one module dropped the count from
    # 22 to 21 and printed "Lower MAX_SEAMLESS … so the ground gained is held",
    # with nothing converted and eight call sites gone from the accounting.
    alias = re.search(r"^import Effect as ([A-Z][A-Za-z0-9_]*)", code, re.M)
    if alias:
        performs += len(re.findall(r"\b" + alias.group(1) + r"\.perform\b", code))

    if not performs:
        continue

    # ⛔ EXPORTED, not merely defined. A `*WithEffect` the module keeps to
    # itself is unreachable by `TestHelpers.simulateEffect`, so counting it
    # would credit progress a test cannot use — and elm-review refuses an
    # export with no consumer, which means an exported seam is one some test
    # actually drives. The two rules together make this count mean "a harness
    # can read this module's plans", which is the claim.
    # ⚠️ Read to the first `import`, not to the first `)` — an exposing list
    # containing `Msg(..)` closes a paren of its own and a lazy match stops
    # there, reporting every module as unexported.
    header = re.split(r"^import ", code, maxsplit=1, flags=re.M)[0]
    exposing = re.search(r"\bexposing\b((?:.|\n)*)", header)
    exported = exposing.group(1) if exposing else ""

    # ⛔ THE PROPERTY IS "NO PLAN IS PERFORMED ANYWHERE BUT THE EDGE", NOT "A
    # FUNCTION WITH THE RIGHT NAME EXISTS".
    #
    # A name check credits a module for DECLARING `updateWithEffect` while every
    # call site still performs its own effects — MEASURED by the platform
    # review: a five-line do-nothing `updateWithEffect : Int -> Int` reclassified
    # a module holding eight performs as converted, and its sites left the
    # accounting entirely. Crediting `initWithEffect` OR `updateWithEffect` has
    # the same shape one level up: `Page/Settings/Profile.elm` exports the init
    # seam and performs two plans inside `update`.
    #
    # ⚖️ So a module is converted when every `Effect.perform` it contains sits
    # in a THIN WRAPPER — a function whose whole body delegates to its
    # `*WithEffect` twin and performs the result once. A module with both
    # `init` and `update` converted therefore holds two performs and is still
    # fully converted, which a flat count cannot express.
    # ⚠️ A wrapper is recognised by what it DOES, not by its name. Matching
    # `init`/`update` missed `Page/Settings/Profile.elm`'s `initWithToken`, a
    # perfectly good wrapper that delegates to `initWithEffect` and performs
    # once — and a name list would have to grow every time someone needs a
    # second entry point.
    wrapper_performs = 0
    for block in code.split("\n\n\n"):
        if "WithEffect" in block:
            wrapper_performs += len(re.findall(r"\bEffect\.perform\b", block))

    stray = performs - wrapper_performs
    has_seam = bool(re.search(r"\b(updateWithEffect|initWithEffect)\b", exported))

    if has_seam and stray > 0:
        half_converted.append((stray, path))

    if has_seam and stray == 0:
        seamed.append(path)
    else:
        seamless.append((stray if stray else performs, path))

    total_sites += performs

seamless.sort(reverse=True)

if mode == "--list":
    print(f"with a seam:    {len(seamed)}")
    print(f"without a seam: {len(seamless)}  ({total_sites} Effect.perform sites)")
    for performs, path in seamless:
        print(f"  {performs:3}  {path}")
    sys.exit(0)

# ⛔ ANTI-VACUITY. A run that finds no plan-building modules at all has drifted
# from the source rather than discovered that the source is perfect, and it
# would pass against any ratchet.
if not seamed and not seamless:
    print("FAIL: found no module calling Effect.perform under frontend/src/.")
    print("That cannot be right, so this gate has drifted from the tree. Fix the")
    print("gate before trusting a green run.")
    sys.exit(1)

# ⛔ THE POPULATION IS CONSERVED BY A REAL CONVERSION. An anti-vacuity check that
# fires only at ZERO is satisfied by almost-total loss — this repository says so
# itself, at check-session-expiry-coverage.sh: "A floor at zero is satisfied by
# almost-total loss, and the printed number was the only tell."
population = len(seamed) + len(seamless)
if population != expected_population:
    verb = "fewer" if population < expected_population else "more"
    print(f"FAIL: {population} plan-building module(s), {verb} than the {expected_population} on record.")
    print("")
    print("A conversion MOVES a module between buckets; it does not change how many")
    print("there are. A module that left the corpus — an aliased `import Effect as X`,")
    print("a rename, a deletion — would otherwise shrink the seamless count and read")
    print("as ground gained.")
    print("")
    print("If the change is deliberate, update EXPECTED_POPULATION in this script and")
    print("say why in the same change.")
    sys.exit(1)

# ⚖️ And the sites, so they cannot grow inside a module already counted as done.
if total_sites > max_total_sites:
    print(f"FAIL: {total_sites} Effect.perform site(s), above the {max_total_sites} on record.")
    print("A module already holding a seam grew new performs, which the module count")
    print("cannot see. Convert them, or raise MAX_TOTAL_SITES deliberately.")
    sys.exit(1)

# ⛔ DECLARED BUT NOT DONE gets its own name, rather than being credited. A seam
# whose module still performs elsewhere is the half-converted state, and a name
# check cannot tell it from the finished one.
if half_converted:
    print(f"FAIL: {len(half_converted)} module(s) declare a seam and still perform their own effects.")
    print("")
    print("Declaring `updateWithEffect` does not move the plans out; the call sites have")
    print("to stop performing them. Until they do, the module is half-converted and")
    print("counting it as done hides the sites that remain.")
    print("")
    for stray, path in sorted(half_converted, reverse=True):
        print(f"  {stray:3} stray Effect.perform site(s)  {path}")
    sys.exit(1)

if len(seamless) > max_seamless:
    print(
        f"FAIL: {len(seamless)} module(s) build a request plan and perform it themselves, "
        f"above the ratchet of {max_seamless}."
    )
    print("")
    print("`TestHelpers.simulateEffect` can only read an Effect that ESCAPES the module.")
    print("Where `Effect.perform` is called inside `update`, the plan is as opaque to the")
    print("harness as the raw `Http.request` it replaced, and no ProgramTest can assert")
    print("what the page sends.")
    print("")
    print("Give the module an `updateWithEffect` (or `initWithEffect`) returning its")
    print("effects as data, and let a thin `update` perform once — `Page/Home.elm:86-105`")
    print("is the reference shape.")
    print("")
    for performs, path in seamless:
        print(f"  {performs:3} Effect.perform site(s)  {path}")
    sys.exit(1)

if len(seamless) < max_seamless:
    print(
        f"FAIL: only {len(seamless)} module(s) lack a seam, but the ratchet still says "
        f"{max_seamless}."
    )
    print("")
    print("This is the ratchet working. Lower MAX_SEAMLESS in this script to")
    print(f"{len(seamless)} in the same change, so the ground gained is held.")
    print("A ratchet nobody lowers is a floor, and a floor absorbs the next regression.")
    sys.exit(1)

print(
    f"OK: {len(seamed)} module(s) expose their effects as data; "
    f"{len(seamless)} still perform their own ({total_sites} site(s)), at the ratchet."
)
PY
