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

mode="${1:-}"

python3 - "$mode" "$MAX_SEAMLESS" <<'PY'
import glob
import re
import sys

mode, max_seamless = sys.argv[1], int(sys.argv[2])

# ⚠️ Comments are blanked before anything is counted. An absence-style check
# that reads its own prose is a recurring defect in this repository: a module
# explaining why it has no seam would otherwise read as having one.
def strip_comments(source):
    source = re.sub(r"\{-(.|\n)*?-\}", "", source)
    return "\n".join(
        "" if re.match(r"^\s*--", line) else re.sub(r"\s--.*$", "", line)
        for line in source.split("\n")
    )


seamless, seamed, total_sites = [], [], 0

for path in sorted(
    glob.glob("frontend/src/Page/**/*.elm", recursive=True)
    + glob.glob("frontend/src/Components/**/*.elm", recursive=True)
):
    with open(path, encoding="utf-8") as handle:
        code = strip_comments(handle.read())

    performs = len(re.findall(r"\bEffect\.perform\b", code))
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
    if re.search(r"\b(updateWithEffect|initWithEffect)\b", exported):
        seamed.append(path)
    else:
        seamless.append((performs, path))
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
