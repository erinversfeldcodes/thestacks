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
# ⛔ AND THERE ARE THREE ROUTES TO JSON, NOT TWO. The first version of this gate
# read the two serializer files and stopped — which left it protecting the two
# routes that had never leaked anything.
#
# The manifest drives three: `api_only` (no column at all), `skip_fields` (the
# generated serializer must not emit it), and `derive_jason`, which writes
# `@derive {Jason.Encoder, only: [...]}` onto the generated Ecto SCHEMA. Fifteen
# schemas carry that attribute, and it means any `json(conn, record)` publishes
# the listed fields with no serializer involved at all. Adding `:password_hash`
# to the `User` entry's `derive_jason` would have been published by that route
# with this gate green.
#
# ⚠️ That is not the hypothetical route — it is the one that actually leaked.
# `listing.proto:132` still says so in the contract: "The seller (embedded User
# struct VIA JASON.ENCODER if preloaded)", which is how a seller's account email
# reached unauthenticated callers on an enumerable public index.
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
#
# ⛔ THE HAND-WRITTEN HALF IS THE ANSWER, NOT A SECOND OPINION. It is tempting to
# read the atom-mention check below as belt-and-braces over the generated one, and
# that undersells it: it is the only thing asserting that a hand-maintained
# take-list — `@user_auth_fields`, `@listing_seller_fields` — cannot NAME a
# credential. That is the caller-side property worth having.
#
# ⚠️ And it is the right property because the obvious alternative is wrong.
# "Every caller of a generated serializer narrows it" would be the natural thing
# to assert, and asserting it teaches `narrowing ⟹ safe` — which is exactly what
# was false for `seller`, where the hand-written serializer DID narrow and the
# defect was on the generated side. Making the caller count irrelevant is the
# point; `skip_fields` plus this gate is how.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import pathlib
import re
import sys

GEN = "apps/core/lib/stacks/gen/proto_json.ex"
HAND = "apps/core/lib/stacks_web/proto_json.ex"

# ⛔ Credentials and single-use tokens. There is no payload on which any of
# these is the right answer, so no override, no baseline, no exemption.
# An entry is either a BARE name — forbidden on every route, in every message —
# or `Full.Module.Path.field`, forbidden only on the schema whose module matches.
#
# ⚠️ Qualification exists because a name can be a credential on one message and
# benign on another: `metadata` is Cloak ciphertext on `audit.audit_log` and an
# ordinary `:map` on three other messages, so it cannot be banned unqualified.
NEVER_SERIALIZE = [
    "password_hash",
    "email_confirmation_token",
    "pending_email_token",
    "pending_email_revert_token",
    "password_reset_token",
    # Added after two reviewers independently swept for credential-shaped names
    # and resolved each to its owning message. Both state the policy in the
    # CONTRACT and neither was enforced anywhere:
    #
    #   partner.proto:46   hmac_secret  "Argon2 hash of the API key. DB-only —
    #                                    never serialized over the wire"
    #   user.proto:201     code_hash    "DB-only; never on the wire"
    #
    # `hmac_secret` is the partner shared secret behind `X-Internal-Token`.
    # Neither is reachable today — neither message has a generated-serializer
    # entry, so there is nothing for codegen to emit them into — but that is
    # accident rather than design, and `ProtoJSON.partner/1` is the last
    # hand-written serializer with no `Gen` base among its nine siblings, so
    # bringing it into line is the natural next tidy. Adding them now is free.
    "hmac_secret",
    "code_hash",
    # Cloak ciphertext on the audit log, qualified because the bare name is
    # benign elsewhere. `Stacks.Audit` encrypts on write and decrypts on read;
    # nothing should ever publish the stored bytes.
    "Stacks.Audit.Entry.metadata",
]

# ⚠️ DELIBERATELY NOT IN THE LIST ABOVE, and the distinction is the reason this
# gate stays usable. The lockout bookkeeping is also kept out of the serializer
# by `skip_fields`, and should be. But "your account is locked until 14:05" is a
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
]

# ⚠️ SEPARATE, because it is not lockout bookkeeping and the rationale above does
# not fit it. `password_reset_sent_at` is a reset-flow timestamp: it says when a
# reset mail was last sent, which is throttling state rather than something a
# product would ever surface as "your account is locked until…". It was grouped
# with the lockout fields on first writing and inherited a displayability
# argument that was never made about it.
#
# It stays unenforced rather than being promoted, on the narrower ground that a
# timestamp is not a credential — knowing WHEN a reset was requested does not
# help anyone use the token, which is enforced above. Recorded apart so the next
# reader does not inherit the wrong reason for it too.
RESET_FLOW_TIMESTAMP = [
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

# ⛔ ROUTE THREE: `@derive {Jason.Encoder, only: [...]}` on the generated Ecto
# schemas. No serializer is involved — `json(conn, record)` publishes whatever
# is in that list.
DERIVE_RE = re.compile(r"@derive \{Jason\.Encoder,\s*only: \[(.*?)\]\}", re.S)

derive_schemas = []
for schema_path in sorted(pathlib.Path("apps/core/lib/stacks/gen").rglob("*.ex")):
    text = schema_path.read_text(encoding="utf-8", errors="ignore")
    match = DERIVE_RE.search(text)
    if not match:
        continue
    module = re.search(r"defmodule ([\w.]+)", text)
    line_no = text[: match.start()].count("\n") + 1
    derive_schemas.append(
        {
            "path": str(schema_path),
            "module": module.group(1) if module else "?",
            "fields": set(re.findall(r":([a-z_0-9]+)", match.group(1))),
            "line": line_no,
        }
    )

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

# ⚠️ The derive route gets its own floor for the same reason as the other two:
# "no credential in any @derive list" is an absence, and an absence is what a
# failed discovery also produces. Fifteen schemas carry the attribute today.
MIN_DERIVE_SCHEMAS = 10
if len(derive_schemas) < MIN_DERIVE_SCHEMAS:
    print(
        f"FAIL: found only {len(derive_schemas)} generated schema(s) with a Jason.Encoder "
        f"derive list, expected at least {MIN_DERIVE_SCHEMAS}.",
        file=sys.stderr,
    )
    print("       An absence check over an unparsed population passes trivially.", file=sys.stderr)
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

def split_entry(entry):
    """`field` -> (None, field); `A.B.C.field` -> ("A.B.C", field)."""
    if "." in entry:
        module, _, field = entry.rpartition(".")
        return module, field
    return None, entry


findings = []

# ⛔ Route three first, because it is the one that actually leaked.
for entry in NEVER_SERIALIZE:
    qualifier, name = split_entry(entry)
    for schema in derive_schemas:
        if qualifier is not None and schema["module"] != qualifier:
            continue
        if name in schema["fields"]:
            findings.append(
                (
                    schema["path"],
                    schema["line"],
                    f"only: [… :{name} …]",
                    f"`{name}` is in {schema['module']}'s Jason.Encoder derive list — "
                    "any `json(conn, record)` publishes it, with no serializer involved",
                )
            )

for entry in NEVER_SERIALIZE:
    qualifier, name = split_entry(entry)
    # A module-qualified entry says nothing about the shared serializer files,
    # which are not per-message — so it is checked on the derive route only.
    if qualifier is not None:
        continue
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
    f"OK: {len(NEVER_SERIALIZE)} credential field(s) absent from all THREE routes to JSON — "
    f"{len(gen_funs)} generated serializer(s), {len(hand_funs)} hand-written function(s), "
    f"and {len(derive_schemas)} Jason.Encoder derive list(s); "
    f"{len(POLICY_NOT_SECRET)} lockout field(s) and "
    f"{len(RESET_FLOW_TIMESTAMP)} reset-flow timestamp deliberately out of scope."
)
PY
