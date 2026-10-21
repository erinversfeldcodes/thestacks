#!/usr/bin/env bash
# test/platform/api_only_is_skipped_test.sh
#
# scripts/check-api-only-is-skipped.sh asserts that a field marked
# `api_only: true` in proto/persisted.exs is also named in its message's
# `skip_fields`, so the generated JSON serializer cannot emit it.
#
# The gate exists because that combination was violated once and three other
# gates were green over it: declaring a message-typed field api_only without
# skipping it made codegen emit `seller: struct.seller` — the raw `%User{}`
# association — into the generated listing serializer, which is the shape a
# deliberately narrow projection had just been added to stop.
#
# ⚠️ The cases below run the gate against SANDBOX manifests, not the real one,
# so they keep asserting as fields come and go. The one case that uses the real
# manifest is the last, and it asserts the gate's floor rather than its verdict.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-api-only-is-skipped.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/scripts" "$SANDBOX/proto"
cp "$GATE" "$SANDBOX/scripts/"

# The gate reads a path relative to its own location's parent, so the sandbox
# has to look like a repository root.
write_manifest() {
    cat > "$SANDBOX/proto/persisted.exs"
}

run_gate() {
    OUT=$(cd "$SANDBOX" && bash scripts/check-api-only-is-skipped.sh 2>&1)
    RC=$?
}

# A manifest with enough api_only fields to clear the gate's floor, so a case
# below fails on the VERDICT rather than on the population check.
#
# ⚠️ Four messages and nine api_only fields is not decoration — the floor is 8
# across 3, and a smaller fixture would make every "allows" case pass for the
# wrong reason and every "refuses" case fail for it.
compliant_manifest() {
    write_manifest <<'EOF'
%{
  tables: [
    %{
      proto_message: "Alpha",
      field_overrides: %{
        one: %{api_only: true},
        two: %{api_only: true},
        three: %{api_only: true}
      }
    },
    %{
      proto_message: "Beta",
      field_overrides: %{
        four: %{api_only: true},
        five: %{api_only: true},
        six: %{api_only: true}
      }
    },
    %{
      proto_message: "Gamma",
      field_overrides: %{
        seven: %{api_only: true},
        eight: %{api_only: true},
        nine: %{api_only: true}
      }
    }
  ],
  json_serializers: [
    %{
      proto_message: "Alpha",
      skip_fields: [:one, :two, :three, :some_id]
    },
    %{
      proto_message: "Beta",
      skip_fields: [:four, :five, :six]
    },
    %{
      proto_message: "Gamma",
      skip_fields: [:seven, :eight, :nine]
    }
  ]
}
EOF
}

# --- a compliant manifest passes --------------------------------------------

compliant_manifest

test_case "every_api_only_field_skipped_passes" "the gate allows a manifest that skips them all"
run_gate
assert_exit_zero "$RC" "the gate passes"
assert_contains "$OUT" "9 api_only field(s) across 3 message(s)" "it reports what it actually read"

# --- one unskipped api_only field fails -------------------------------------

# ⛔ This is the seller exposure, reduced: the field is api_only, the message has
# a serializer, and the field is absent from skip_fields — so codegen emits the
# raw association.
write_manifest <<'EOF'
%{
  tables: [
    %{
      proto_message: "Alpha",
      field_overrides: %{
        one: %{api_only: true},
        two: %{api_only: true},
        three: %{api_only: true}
      }
    },
    %{
      proto_message: "Beta",
      field_overrides: %{
        four: %{api_only: true},
        five: %{api_only: true},
        six: %{api_only: true}
      }
    },
    %{
      proto_message: "Gamma",
      field_overrides: %{
        seven: %{api_only: true},
        eight: %{api_only: true},
        nine: %{api_only: true}
      }
    }
  ],
  json_serializers: [
    %{
      proto_message: "Alpha",
      skip_fields: [:one, :two, :some_id]
    },
    %{
      proto_message: "Beta",
      skip_fields: [:four, :five, :six]
    },
    %{
      proto_message: "Gamma",
      skip_fields: [:seven, :eight, :nine]
    }
  ]
}
EOF

test_case "an_unskipped_api_only_field_is_refused" "the field codegen would emit raw is named"
run_gate
assert_exit_nonzero "$RC" "the gate refuses"
assert_contains "$OUT" "Alpha" "the message is named"
assert_contains "$OUT" "api_only but not skipped: three" "the field is named"
assert_contains "$OUT" "raw Ecto association" "the consequence is stated, not just the rule"

# --- the converse is NOT checked --------------------------------------------

# ⛔ One-directional by design, and this case pins that. `some_id` is skipped
# from Alpha's serializer without being api_only, which is correct and common:
# a hand-written serializer narrows for reasons unrelated to whether a column
# exists. A gate that checked both directions would force every such field into
# an api_only flag that would then be wrong about the database.
compliant_manifest

test_case "a_skipped_field_need_not_be_api_only" "narrowing a serializer is not a claim about columns"
run_gate
assert_exit_zero "$RC" "the gate passes with :some_id skipped but not api_only"
assert_not_contains "$OUT" "some_id" "it does not complain about the extra skip"

# --- a message with no serializer is reported, not failed -------------------

write_manifest <<'EOF'
%{
  tables: [
    %{
      proto_message: "Alpha",
      field_overrides: %{
        one: %{api_only: true},
        two: %{api_only: true},
        three: %{api_only: true}
      }
    },
    %{
      proto_message: "Beta",
      field_overrides: %{
        four: %{api_only: true},
        five: %{api_only: true},
        six: %{api_only: true}
      }
    },
    %{
      proto_message: "Delta",
      field_overrides: %{
        seven: %{api_only: true},
        eight: %{api_only: true},
        nine: %{api_only: true}
      }
    }
  ],
  json_serializers: [
    %{
      proto_message: "Alpha",
      skip_fields: [:one, :two, :three]
    },
    %{
      proto_message: "Beta",
      skip_fields: [:four, :five, :six]
    }
  ]
}
EOF

test_case "a_message_with_no_serializer_is_reported" "nothing to skip is not a violation, but it is said out loud"
run_gate
assert_exit_zero "$RC" "the gate passes: there is no generated serializer to suppress"
assert_contains "$OUT" "no generated serializer" "the exemption is reported rather than silent"
assert_contains "$OUT" "Delta" "and the message is named, so a serializer added later is not a surprise"

# --- an unreadable manifest is a refusal, not a pass ------------------------

# ⛔ The fall-through must default to HAZARD. An empty result is what a correct
# manifest produces AND what a drifted entry shape produces, and those must not
# look the same — which is the defect class this repository keeps finding.
write_manifest <<'EOF'
%{
  tables: [],
  json_serializers: []
}
EOF

test_case "an_empty_manifest_is_refused" "a clean verdict over nothing is refused"
run_gate
assert_exit_nonzero "$RC" "the gate refuses rather than reporting a clean manifest"
assert_contains "$OUT" "parsed only 0 api_only field(s)" "the refusal says what it read"
assert_contains "$OUT" "stopped matching" "and names the likely cause"

# --- the floor is below the real manifest, and the real manifest passes -----

# ⚠️ Asserted against the REAL manifest, because a floor is only meaningful
# relative to the population it guards. If the repository's own count ever drops
# below the floor the gate starts refusing a correct tree, and that is a failure
# worth catching here rather than in someone's lint run.
test_case "the_real_manifest_clears_the_floor" "the gate's floor is calibrated to the tree it guards"
OUT=$(cd "$REPO_ROOT" && bash scripts/check-api-only-is-skipped.sh 2>&1)
RC=$?
assert_exit_zero "$RC" "the real manifest passes"
assert_contains "$OUT" "all skipped by their serializer" "every api_only field is skipped today"

summarise
