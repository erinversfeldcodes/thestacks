#!/usr/bin/env bash
# A credential must not appear in any JSON serializer, generated or hand-written.
#
# ⛔ WHAT WAS UNGUARDED. `proto/persisted.exs` keeps an Argon2 password hash and
# four single-use auth tokens out of the generated serializer by naming them in
# the `User` entry's `skip_fields`. That list entry was the only thing holding
# the line, and every existing gate is structurally blind to it:
#
#   * `check-api-only-is-skipped.sh` cannot cover them, correctly — they are
#     real columns, so they are not `api_only`, and that gate is about fields
#     with no column at all.
#   * `check-protojson-completeness.sh` cannot see them, because `skip_fields`
#     removes a field from the GENERATED shape, which is the left-hand side of
#     its set difference. This is the same mechanism that hid `seller_id` until
#     a review found it by reading the manifest.
#   * `mix proto.sync --check` compares generated output against what it would
#     generate now. It catches an UNREGENERATED tree; it never questions the
#     decision, because deleting a `skip_fields` entry and regenerating is a
#     perfectly consistent pair of changes.
#
# So deleting one line from a manifest would have put a password hash into a
# serializer with three gates green. Nothing was exposed — `Gen.user/1` emits
# none of them today and both of its callers `Map.take` — but that is the same
# argument that held for `seller` right up until it did not, and `Gen.user/1`
# has TWO callers, so the narrowing argument is weaker here than it was there.
#
# ⛔ THE LIST LIVES IN THIS FILE, NOT IN THE MANIFEST IT PROTECTS. Reading it
# from `persisted.exs` would mean deleting the entry deletes the assertion, and
# the gate would go green on exactly the change it exists to refuse. A guard
# whose expectations come from the thing it guards is not a guard.
#
# ⚠️ ONE-DIRECTIONAL, and NOT the two-way check rejected earlier. That rejected
# form was `skipped ⟹ api_only`, which is false by design for `seller_id`,
# `book_id`, `post_id` and `created_at`. This is `must-not-be-serialized ⟹
# absent from every serializer`, which says nothing about those fields at all.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import re
import sys

GEN = "apps/core/lib/stacks/gen/proto_json.ex"
HAND = "apps/core/lib/stacks_web/proto_json.ex"

# ⛔ Credentials and single-use tokens. There is no payload on which any of
# these is the right answer, so no override, no baseline, no exemption.
NEVER_SERIALIZE = [
    "password_hash",
    "email_confirmation_token",
    "pending_email_token",
    "pending_email_revert_token",
    "password_reset_token",
]

# ⚠️ DELIBERATELY NOT IN THE LIST ABOVE, and the distinction is the reason this
# gate stays usable. The lockout bookkeeping — `failed_login_count`,
# `failed_login_first_at`, `locked_until`, `lockout_duration_seconds`,
# `password_reset_sent_at` — is also kept out of the serializer by
# `skip_fields`, and should be. But "your account is locked until 14:05" is a
# message a product could legitimately decide to show, so a hard refusal here
# would block a reasonable feature and the gate would be edited to allow it —
# at which point the credential entries lose their protection too.
#
# They are listed here so that absence from the enforced list is a recorded
# decision rather than an oversight.
POLICY_NOT_SECRET = [
    "failed_login_count",
    "failed_login_first_at",
    "locked_until",
    "lockout_duration_seconds",
    "password_reset_sent_at",
]


def read(path):
    try:
        return open(path, encoding="utf-8").read()
    except OSError as exc:
        print(f"FAIL: cannot read {path}: {exc}", file=sys.stderr)
        print("       Nothing was checked. This is a refusal, not a pass.", file=sys.stderr)
        raise SystemExit(1)


gen_src = read(GEN)
hand_src = read(HAND)

# ⚠️ Anti-vacuity on BOTH inputs, because every check below is an absence and an
# absence is what an unparsed file also produces. The generated file defines one
# serializer per persisted message; a number this low means the parse stopped
# matching rather than that the serializers are gone.
gen_funs = re.findall(r"\n  def ([a-z_]+)\(struct\) do\n", gen_src)
hand_funs = re.findall(r"\n  defp? ([a-z_]+)\(", hand_src)

if len(gen_funs) < 5:
    print(f"FAIL: parsed only {len(gen_funs)} generated serializer(s) from {GEN}.", file=sys.stderr)
    print("       An absence check over an unparsed file passes trivially.", file=sys.stderr)
    raise SystemExit(1)

if len(hand_funs) < 10:
    print(f"FAIL: parsed only {len(hand_funs)} function(s) from {HAND}.", file=sys.stderr)
    print("       An absence check over an unparsed file passes trivially.", file=sys.stderr)
    raise SystemExit(1)

if not NEVER_SERIALIZE:
    print("FAIL: the NEVER_SERIALIZE list is empty, so this gate asserts nothing.", file=sys.stderr)
    raise SystemExit(1)


def strip_comments(src):
    """Drop `#` comments, keeping `#{` interpolation and `#` inside strings.

    ⚠️ Required: this file's siblings have five recorded instances of a gate
    reading its own prose as a violation, and the names below appear in comments
    in both files under inspection.
    """
    out = []
    for line in src.split("\n"):
        kept = []
        in_string = False
        i = 0
        while i < len(line):
            ch = line[i]
            if ch == '"':
                in_string = not in_string
            elif ch == "#" and not in_string:
                if i + 1 < len(line) and line[i + 1] == "{":
                    kept.append(line[i:])
                    i = len(line)
                    continue
                break
            kept.append(ch)
            i += 1
        out.append("".join(kept))
    return "\n".join(out)


gen_code = strip_comments(gen_src)
hand_code = strip_comments(hand_src)

findings = []
for name in NEVER_SERIALIZE:
    # In the generated file a field is emitted as `name: struct.name`.
    for n, line in enumerate(gen_code.split("\n"), 1):
        if re.match(rf"^\s+{re.escape(name)}:\s", line):
            findings.append((GEN, n, line.strip(), f"`{name}` is EMITTED by a generated serializer"))
    # In the hand-written file the field would appear as an atom — a take-list
    # entry, a Map.merge key or a module-attribute roster all spell it `:name`.
    for n, line in enumerate(hand_code.split("\n"), 1):
        if re.search(rf"(?<![a-z_]):{re.escape(name)}\b", line):
            findings.append((HAND, n, line.strip(), f"`{name}` is named in a hand-written serializer"))

if findings:
    print(f"FAIL: {len(findings)} site(s) put a credential into a JSON serializer:", file=sys.stderr)
    for path, n, line, why in findings:
        print(f"  {path}:{n} — {why}", file=sys.stderr)
        print(f"      {line}", file=sys.stderr)
    print(
        "\nThese are credentials and single-use tokens. There is no payload on which any of\n"
        "them is the right answer, so there is no baseline to add the pair to and no override\n"
        "to set — the serializer is what has to change.\n\n"
        "If a field above is genuinely not a credential, it does not belong in this gate's\n"
        "NEVER_SERIALIZE list, and removing it from that list is the change to argue for.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    f"OK: {len(NEVER_SERIALIZE)} credential field(s) absent from "
    f"{len(gen_funs)} generated and {len(hand_funs)} hand-written serializer function(s); "
    f"{len(POLICY_NOT_SECRET)} lockout field(s) deliberately out of scope."
)
PY
