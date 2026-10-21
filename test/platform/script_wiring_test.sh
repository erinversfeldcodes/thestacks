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

# --- a gate's own test fixture is a caller ---------------------------------

# `test/**/*.sh` was NOT in the corpus, so a gate exercised only by its own test
# suite read as an orphan. That had a second-order cost beyond an incomplete
# inventory: the only way to clear such a script was to name it somewhere the
# corpus could see, and the cheapest place is a data table inside another
# script — at which point a bare MENTION is standing in for an invocation,
# which is the thing the comment-stripping above exists to prevent. On the real
# repository the widened corpus moved 30-odd scripts from "no test visible" to
# naming the fixture that runs them.
mkdir -p "$SANDBOX/test/platform"
cat > "$SANDBOX/test/platform/orphan_test.sh" <<'EOF'
#!/usr/bin/env bash
# orphan_test.sh — exercises the gate
bash scripts/orphan.sh
EOF

test_case "a_test_fixture_is_a_caller" "a script exercised only by its own test suite is wired"
(cd "$SANDBOX" && bash scripts/check-script-wiring.sh --write >/dev/null 2>&1)
run_gate
assert_exit_zero "$RC" "the gate passes: the fixture that runs the script counts as its caller"
assert_contains "$OUT" "all wired" "no script is reported as an orphan"

# --- but a test that only TALKS about a script wires nothing ----------------

# The corpus widened; the mention rule did not. Without this case the widening
# could silently become the prose-lifting loophole it was meant to remove.
cat > "$SANDBOX/test/platform/orphan_test.sh" <<'EOF'
#!/usr/bin/env bash
# orphan_test.sh — this suite used to run scripts/orphan.sh before it was
# replaced, and now covers the replacement instead.
echo covered
EOF

test_case "comment_mention_in_a_test_is_not_a_caller" "widening the corpus did not widen what counts as a call"
run_gate
assert_exit_nonzero "$RC" "the gate fails: prose in a fixture is not an invocation"
assert_contains "$OUT" "NO caller" "the failure is the orphan check, not a stale inventory"
assert_contains "$OUT" "scripts/orphan.sh" "the orphan is named"

# --- a bare quoted string is DATA, not a call ------------------------------

# ⛔ The route comment-stripping leaves open. An exemption list, a fixture
# pairing, an assertion description or a generated-file banner names a script on
# a line of CODE, so the caller search counts it and the inventory records an
# invocation that does not exist.
#
# MEASURED on the real repository: the discriminator removed ELEVEN false
# callers, including this gate recording `check-sigpipe-hazards.sh` as a caller
# of `check-rls-scope.sh` (a fixture pairing), `gen_python_proto.py` as a caller
# of three `gen-*-proto.sh` scripts (a "Regenerate: …" banner it writes into
# generated files), and `install-hooks.sh` as a caller of `pre-stop-lint.sh` (a
# path in a `chmod +x` array — it makes the hook executable and never runs it).
# No script lost its only caller, so nothing became an orphan.
write_script "orphan.sh" "orphan.sh — named as data, called by nobody"
cat > "$SANDBOX/scripts/lister.sh" <<'EOF'
#!/usr/bin/env bash
# lister.sh — names the script in a data array without ever running it
EXEMPT_FILES=(
    "scripts/orphan.sh"
)
echo "${EXEMPT_FILES[@]}"
EOF
write_justfile <<'EOF'
build:
    bash scripts/lister.sh
EOF

test_case "a_bare_quoted_string_is_not_a_caller" "naming a script in a data array wires nothing"
run_gate
assert_exit_nonzero "$RC" "the gate still reports the orphan"
assert_contains "$OUT" "scripts/orphan.sh" "the orphan is named despite appearing in code"
assert_contains "$OUT" "NO caller" "the failure is the orphan check, not a stale inventory"

# --- but a dispatcher's bare WORD still counts -----------------------------

# ⚠️ The anti-over-reach control, and it is why the rule is "a line that is only
# a quoted string" rather than "a line mentioning a script". This repo dispatches
# gates through its own shell functions — `gate check-css.sh` — and the stricter
# fix that asked what an invocation looks like reported 11 live scripts as
# orphans. `gate orphan.sh` is an unquoted argument and must keep counting.
cat > "$SANDBOX/scripts/lister.sh" <<'EOF'
#!/usr/bin/env bash
# lister.sh — dispatches through a local function
gate() { bash "scripts/$1"; }
gate orphan.sh
EOF

test_case "an_unquoted_dispatcher_argument_still_counts" "the data rule did not swallow the dispatcher idiom"
(cd "$SANDBOX" && bash scripts/check-script-wiring.sh --write >/dev/null 2>&1)
run_gate
assert_exit_zero "$RC" "the gate passes: 'gate orphan.sh' is still a call"
assert_contains "$OUT" "all wired" "no script is reported as an orphan"

# --- and in DECLARATIVE config a quoted string IS the invocation -----------

# ⛔ The condition on the data rule, and the reason it is a condition rather
# than caution. In a shell or Python file a bare string literal on its own line
# is never how anything runs a script. In a declarative config it is the only
# way: this repo wires its Stop hook as `"command": "…/pre-stop-lint.sh"` in
# `.claude/settings.json`, and a config listing commands one per line would put
# a bare quoted path there legitimately.
#
# MEASURED: the ungated rule does not actually strip the real settings.json
# line — it carries a key prefix and internal escaped quotes, so the
# no-internal-quote class cannot span it. But the shape BELOW is stripped by
# it, and there are zero instances of it in the declarative corpus today, which
# is why the gate went in before one appeared rather than after.
rm -f "$SANDBOX/scripts/lister.sh"
write_justfile <<'EOF'
build:
    echo building
EOF
mkdir -p "$SANDBOX/.claude"
cat > "$SANDBOX/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "Stop": [
      "scripts/orphan.sh"
    ]
  }
}
EOF

test_case "a_quoted_command_in_declarative_config_is_a_caller" "the data rule is gated on source kind"
(cd "$SANDBOX" && bash scripts/check-script-wiring.sh --write >/dev/null 2>&1)
run_gate
assert_exit_zero "$RC" "the gate passes: a bare quoted path in config is an invocation"
assert_contains "$OUT" "all wired" "the script is not reported as an orphan"
assert_contains "$(cat "$SANDBOX/scripts/README.md")" ".claude/settings.json" \
    "and the config is recorded as its caller"

summarise
