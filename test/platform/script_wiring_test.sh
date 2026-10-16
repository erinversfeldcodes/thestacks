#!/usr/bin/env bash
# test/platform/script_wiring_test.sh
#
# scripts/check-script-wiring.sh claims that "a script with no caller cannot sit
# here silently". This suite exists because that claim was false in both
# directions, and the gate had no test at all.
#
# The caller search was a bare substring match over whole files, so merely
# NAMING a script recorded the naming file as a caller. Two consequences:
#
#   * "called by" listed files that invoke nothing. Measured on the real
#     repository: `justfile` was recorded as calling `deploy-stack.sh` from one
#     comment, `upload.spec.ts` as calling the pre-commit hook, and both git
#     hooks as calling the installer that installs them.
#   * an orphaned script could be lifted off the orphan list by one sentence of
#     prose about it — which is the gate's own claim failing.
#
# The sandbox below is a minimal corpus rather than the real repository, so
# these cases stay asserted as the project's scripts come and go.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-script-wiring.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/scripts"

# The gate resolves its corpus relative to the working directory, so the sandbox
# has to look like a repository root.
cp "$GATE" "$SANDBOX/scripts/"

write_script() {
    printf '#!/usr/bin/env bash\n# %s\necho hi\n' "$2" > "$SANDBOX/scripts/$1"
}

# Every sandbox justfile invokes the GATE as well as whatever the case needs.
# Without that line the gate is its own orphan and every case below fails for a
# reason unrelated to what it asserts — which is how this helper came to exist.
write_justfile() {
    {
        printf 'wiring:\n    bash scripts/check-script-wiring.sh\n\n'
        cat
    } > "$SANDBOX/justfile"
}

run_gate() {
    OUT=$(cd "$SANDBOX" && bash scripts/check-script-wiring.sh 2>&1)
    RC=$?
}

# --- a script named only in a comment is NOT wired ------------------------

write_script "orphan.sh" "orphan.sh — nothing calls this"
write_justfile <<'EOF'
# This recipe used to run scripts/orphan.sh before it was replaced.
build:
    echo building
EOF

test_case "comment_mention_is_not_a_caller" "a script named only in a comment stays an orphan"
run_gate
assert_exit_nonzero "$RC" "the gate fails on the orphan"
assert_contains "$OUT" "scripts/orphan.sh" "the orphan is named"
assert_contains "$OUT" "NO caller" "the output says what is wrong"

# --- the same script, actually invoked, IS wired ---------------------------

write_justfile <<'EOF'
# This recipe runs the sweep.
build:
    bash scripts/orphan.sh
EOF

test_case "real_invocation_is_a_caller" "an invoked script is recorded as wired"
run_gate
# Still non-zero on the FIRST run only because the inventory is stale; write it
# and re-check, which is the workflow the gate documents.
(cd "$SANDBOX" && bash scripts/check-script-wiring.sh --write >/dev/null 2>&1)
run_gate
assert_exit_zero "$RC" "the gate passes once the script is genuinely invoked"
assert_contains "$OUT" "all wired" "the summary says every script is wired"

# --- invocation through a project-local dispatcher still counts -------------

# ⚠️ This is the case that REFUTED the stricter fix. Requiring the mention to
# follow `bash`/`sh`/`python`/a path separator reported 11 live scripts as
# orphans, because this repo dispatches its gates through its own shell
# functions — `lint-elm.sh` runs `gate check-css.sh`, `install-hooks.sh` runs
# `install_hook "pre-commit"`. Neither is distinguishable from prose by shape.
cat > "$SANDBOX/scripts/dispatcher.sh" <<'EOF'
#!/usr/bin/env bash
# dispatcher.sh — runs the gates through a local function
gate() { bash "scripts/$1"; }
gate orphan.sh
EOF
write_justfile <<'EOF'
build:
    bash scripts/dispatcher.sh
EOF

test_case "local_dispatcher_counts" "a name passed to a project-local dispatcher is a call"
(cd "$SANDBOX" && bash scripts/check-script-wiring.sh --write >/dev/null 2>&1)
run_gate
assert_exit_zero "$RC" "the gate passes: 'gate orphan.sh' is recognised as a call"
assert_contains "$OUT" "all wired" "no script is reported as an orphan"

# --- the generated inventory is never itself a caller ----------------------

test_case "inventory_is_not_a_caller" "the gate's own output cannot wire everything"
assert_path_exists "$SANDBOX/scripts/README.md" "the inventory was written"
# Remove every real caller but keep the inventory, which names every script.
write_justfile <<'EOF'
build:
    echo building
EOF
rm -f "$SANDBOX/scripts/dispatcher.sh"
run_gate
assert_exit_nonzero "$RC" "the orphan is reported again despite the inventory naming it"
assert_contains "$OUT" "scripts/orphan.sh" "the inventory does not count as a caller"

summarise
