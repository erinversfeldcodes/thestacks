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
# manifest is the last, and it asserts the gate's declared count rather than its
# verdict.

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

# A manifest matching the gate's DECLARED COUNT exactly, so a case below fails
# on the VERDICT rather than on the population check.
#
# ⚠️ Twelve api_only fields across four messages is not decoration — the gate
# declares exactly that, in both directions, so a sandbox of any other size
# makes every "allows" case fail for the wrong reason and every "refuses" case
# pass for one. These manifests were 9 across 3 while the gate carried a FLOOR
# of 8 across 3; replacing the floor with a declared count meant resizing every
# one of them, which is the cost of the stricter instrument and worth naming.
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
    },
    %{
      proto_message: "Delta",
      field_overrides: %{
        ten: %{api_only: true},
        eleven: %{api_only: true},
        twelve: %{api_only: true}
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
    },
    %{
      proto_message: "Delta",
      skip_fields: [:ten, :eleven, :twelve]
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
assert_contains "$OUT" "12 api_only field(s) across 4 message(s)" "it reports what it actually read"

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
    },
    %{
      proto_message: "Delta",
      field_overrides: %{
        ten: %{api_only: true},
        eleven: %{api_only: true},
        twelve: %{api_only: true}
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
    },
    %{
      proto_message: "Delta",
      skip_fields: [:ten, :eleven, :twelve]
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
      proto_message: "Gamma",
      field_overrides: %{
        seven: %{api_only: true},
        eight: %{api_only: true},
        nine: %{api_only: true}
      }
    },
    %{
      proto_message: "Delta",
      field_overrides: %{
        ten: %{api_only: true},
        eleven: %{api_only: true},
        twelve: %{api_only: true}
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
    },
    %{
      proto_message: "Gamma",
      skip_fields: [:seven, :eight, :nine]
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
assert_contains "$OUT" "parsed 0 api_only field(s)" "the refusal says what it read"
assert_contains "$OUT" "expected exactly 12 across 4" "and what it expected"
assert_contains "$OUT" "stopped matching" "and names the likely cause"

# --- the floor is below the real manifest, and the real manifest passes -----

# ⚠️ Asserted against the REAL manifest, because a declared count is a claim
# about this repository and nothing else. If the manifest and the two constants
# ever disagree the gate refuses a correct tree, and that is a failure worth
# catching here rather than in someone's lint run.
test_case "the_real_manifest_matches_the_declared_count" "the gate's floor is calibrated to the tree it guards"
OUT=$(cd "$REPO_ROOT" && bash scripts/check-api-only-is-skipped.sh 2>&1)
RC=$?
assert_exit_zero "$RC" "the real manifest passes"
assert_contains "$OUT" "all skipped by their serializer" "every api_only field is skipped today"

# --- the declared count fails in BOTH directions ---------------------------

# ⛔ This is what a floor could not do. The gate carried `MIN_API_ONLY = 8`
# against an actual 12, so up to four fields could drop out of the parse
# without tripping it — observable in the printed count, never enforced.
#
# ⚠️ A floor is the right instrument when a population grows for reasons nobody
# decides. `api_only` fields are added one at a time by a person editing a
# manifest, so an exact count makes that edit a recorded decision visible in a
# diff — the same argument as `EXPECTED_ASSERTIONS` in the posture gate.

# FEWER than declared: eleven fields across four messages.
write_manifest <<'EOF'
%{
  tables: [
    %{
      proto_message: "Alpha",
      field_overrides: %{
        one: %{api_only: true},
        two: %{api_only: true}
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
    },
    %{
      proto_message: "Delta",
      field_overrides: %{
        ten: %{api_only: true},
        eleven: %{api_only: true},
        twelve: %{api_only: true}
      }
    }
  ],
  json_serializers: [
    %{
      proto_message: "Alpha",
      skip_fields: [:one, :two]
    },
    %{
      proto_message: "Beta",
      skip_fields: [:four, :five, :six]
    },
    %{
      proto_message: "Gamma",
      skip_fields: [:seven, :eight, :nine]
    },
    %{
      proto_message: "Delta",
      skip_fields: [:ten, :eleven, :twelve]
    }
  ]
}
EOF

test_case "fewer_fields_than_declared_is_refused" "a floor would have passed this"
run_gate
assert_exit_nonzero "$RC" "eleven fields against a declared twelve is refused"
assert_contains "$OUT" "expected exactly 12 across 4" "the refusal states the declared count"
assert_contains "$OUT" "FEWER means" "and distinguishes a drifted parse from a removed flag"

# MORE than declared: thirteen fields across four messages, all correctly skipped,
# so the only thing wrong is that nobody recorded the addition.
write_manifest <<'EOF'
%{
  tables: [
    %{
      proto_message: "Alpha",
      field_overrides: %{
        one: %{api_only: true},
        two: %{api_only: true},
        three: %{api_only: true},
        extra: %{api_only: true}
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
    },
    %{
      proto_message: "Delta",
      field_overrides: %{
        ten: %{api_only: true},
        eleven: %{api_only: true},
        twelve: %{api_only: true}
      }
    }
  ],
  json_serializers: [
    %{
      proto_message: "Alpha",
      skip_fields: [:one, :two, :three, :extra]
    },
    %{
      proto_message: "Beta",
      skip_fields: [:four, :five, :six]
    },
    %{
      proto_message: "Gamma",
      skip_fields: [:seven, :eight, :nine]
    },
    %{
      proto_message: "Delta",
      skip_fields: [:ten, :eleven, :twelve]
    }
  ]
}
EOF

test_case "more_fields_than_declared_is_refused" "an unrecorded addition is refused even when correctly skipped"
run_gate
assert_exit_nonzero "$RC" "thirteen fields against a declared twelve is refused"
assert_contains "$OUT" "MORE means" "and says why an addition needs recording"
assert_contains "$OUT" "Alpha: extra" "and lists what it found, so the diff is readable"

summarise
