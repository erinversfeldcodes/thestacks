#!/usr/bin/env bash
# An api_only field must also be skipped by its message's JSON serializer.
#
# ⛔ WHAT THIS CATCHES, AND WHY THE EXISTING GATES DID NOT.
#
# `proto/persisted.exs` carries two independent decisions about the same field.
# `api_only: true` in a message's `field_overrides` says "no database column" —
# it keeps the field out of the Ecto schema, the migration, the dbt model and
# schema.yml. `skip_fields` in that message's `json_serializers` entry says "the
# generated serializer must not emit this" — which is what a field needs when
# the hand-written serializer replaces it with a narrow projection.
#
# A field that is api_only and NOT skipped gets emitted by codegen as
# `field: struct.field`, and for a message-typed field that value is the raw
# Ecto association — every column of it. MEASURED: declaring `ListingSeller
# seller = 18` with `api_only: true` but no `skip_fields` entry generated
# `seller: struct.seller` into `Gen.listing/1`, which is the raw `%User{}` and
# precisely the shape the narrow projection had just been added to stop. Nothing
# escaped only because the single caller `Map.take`s immediately.
#
# ⚠️ Three gates were green over that. `lint-proto.sh` checks the five codegen
# targets agree with each other, and they did. `check-protojson-completeness.sh`
# DID report it, as `listing drops seller` — a set difference naming neither
# set, which reads like noise next to a known false-positive class in the same
# gate, and was very nearly pinned into its BASELINE as one. And nothing watched
# `persisted.exs` itself.
#
# ⚠️ ONE-DIRECTIONAL, deliberately. The converse is false by design: `seller_id`,
# `book_id`, `post_id` and `created_at` are all skipped from a serializer without
# being api_only, because a hand-written serializer narrows for reasons that have
# nothing to do with whether a column exists. Checking both directions would
# force those into a flag that would then be wrong about the database.
#
# This reads `proto/persisted.exs` and nothing else — no compilation, no
# generated output. That is the point: `mix proto.sync --check` has crashed
# before, and a gate that needs codegen to run cannot speak about a tree where
# codegen is broken, which is exactly when this question matters.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import re
import sys

MANIFEST = "proto/persisted.exs"

try:
    src = open(MANIFEST, encoding="utf-8").read()
except OSError as exc:
    print(f"FAIL: cannot read {MANIFEST}: {exc}", file=sys.stderr)
    raise SystemExit(1)

# Entries are split on `proto_message:` rather than parsed as Elixir. Both the
# schema entries and the json_serializers entries carry that key, so one pass
# collects both sides keyed by message name.
api_only = {}
skips = {}

for m in re.finditer(r'proto_message:\s*"([A-Za-z0-9_]+)"(.*?)(?=proto_message:\s*"|\Z)', src, re.S):
    message, body = m.group(1), m.group(2)

    # ⛔ `[^{}]*` — the body must be BRACE-FREE, so this cannot reach through a
    # nested map and capture the wrapper's name.
    #
    # The first version was `%\{[^}]*\bapi_only:\s*true[^}]*\}`, and `[^}]`
    # matches newlines, so `field_overrides: %{` followed anywhere below by an
    # `api_only: true` captured `field_overrides` as the field name. It gave the
    # right answer on the real manifest purely because some other override
    # closes a brace before the first `api_only` appears there — a message whose
    # FIRST override were api_only would have broken it.
    #
    # Caught by this gate's own fixture, whose sandbox manifest happens to put
    # an api_only override first. Worth the comment because the real-manifest run
    # was green and agreed with an independent hand count of 12, which is exactly
    # the kind of agreement that retires a suspicion too early.
    for field, overrides in re.findall(r"(\w+):\s*%\{([^{}]*)\}", body):
        if re.search(r"\bapi_only:\s*true", overrides):
            api_only.setdefault(message, set()).add(field)

    skip = re.search(r"skip_fields:\s*\[([^\]]*)\]", body)
    if skip:
        skips.setdefault(message, set()).update(re.findall(r":(\w+)", skip.group(1)))

# ⛔ Anti-vacuity, and it is the whole difference between this gate working and
# this gate reporting a clean tree it never read. An empty set difference is
# what a correct manifest produces AND what a drifted regex produces, so the
# population has to be asserted.
# ⛔ A DECLARED COUNT, not a floor with slack.
#
# This was a floor of 8 fields across 3 messages against an actual 12 across 4 —
# so up to four `api_only` fields could have dropped out of the parse without
# tripping it. The printed count made that observable; nothing made it
# ENFORCED, and "observable" is what a reader has to go looking for.
#
# ⚠️ A floor was the wrong instrument here, and the reason generalises. A floor
# is right when the population grows for reasons nobody decides — shell scripts,
# say. `api_only` fields are added one at a time by a person editing a manifest,
# so an exact count makes that edit a RECORDED DECISION visible in a diff, which
# is the same argument as pinning `EXPECTED_ASSERTIONS` in the posture gate and
# the same argument that put `seller_id` in a baseline instead of hiding it.
#
# It fails in both directions on purpose: fewer than expected means the parse
# drifted or a flag was removed, more means one was added without the review
# that should accompany publishing a field with no column.
EXPECTED_API_ONLY_FIELDS = 13
EXPECTED_API_ONLY_MESSAGES = 4

found_fields = sum(len(v) for v in api_only.values())
if found_fields != EXPECTED_API_ONLY_FIELDS or len(api_only) != EXPECTED_API_ONLY_MESSAGES:
    print(
        f"FAIL: parsed {found_fields} api_only field(s) across {len(api_only)} message(s) "
        f"from {MANIFEST}; expected exactly {EXPECTED_API_ONLY_FIELDS} across "
        f"{EXPECTED_API_ONLY_MESSAGES}.",
        file=sys.stderr,
    )
    print(
        "       FEWER means either the entry shape stopped matching — an unread manifest\n"
        "       produces the same empty result as a correct one — or a flag was removed.\n"
        "       MORE means a field was marked api_only without the review that should\n"
        "       accompany publishing a field that has no column.\n"
        "\n"
        "       Update the two expected counts in the same change, so the population is a\n"
        "       recorded decision rather than slack nobody has to justify.",
        file=sys.stderr,
    )
    for message in sorted(api_only):
        print(f"         {message}: {', '.join(sorted(api_only[message]))}", file=sys.stderr)
    raise SystemExit(1)

violations = []
no_serializer = []
for message, fields in sorted(api_only.items()):
    if message not in skips:
        # Nothing to skip: this message has no generated JSON serializer, so
        # there is no emission to suppress. Reported, not failed — but reported,
        # because a serializer added later inherits the obligation silently.
        no_serializer.append((message, sorted(fields)))
        continue
    missing = sorted(fields - skips[message])
    if missing:
        violations.append((message, missing))

if violations:
    print(
        f"FAIL: {len(violations)} message(s) carry an api_only field their serializer emits:",
        file=sys.stderr,
    )
    for message, missing in violations:
        print(f"  {message:<22} api_only but not skipped: {', '.join(missing)}", file=sys.stderr)
    print(
        "\nThe generated serializer will emit `field: struct.field` for each of these. For a\n"
        "message-typed field that is the raw Ecto association — every column of it, including\n"
        "any personal data the record holds — on whatever payload the serializer feeds.\n"
        "\n"
        "Add the field to that message's `skip_fields` in the `json_serializers` entry, beside\n"
        "the others. If the generated serializer is genuinely meant to carry it, the field is\n"
        "not api_only and the override is what should change.",
        file=sys.stderr,
    )
    raise SystemExit(1)

summary = f"OK: {found_fields} api_only field(s) across {len(api_only)} message(s), all skipped by their serializer."
if no_serializer:
    names = ", ".join(m for m, _ in no_serializer)
    summary += f" {len(no_serializer)} message(s) have no generated serializer ({names})."
print(summary)
PY
