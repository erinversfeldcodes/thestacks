#!/usr/bin/env bash
# test/platform/sweep_preview_orphans_test.sh
#
# `scripts/sweep-preview-orphans.sh` is the weekly backstop that collects
# preview resources no open PR owns. It covered Fly apps and Neon branches, and
# a preview deploy creates a THIRD kind of resource: a Modal vision app.
#
# ⛔ Nothing collected those. Measured 2026-10-19: 26 Modal apps existed and 24
# were orphans, the oldest from 20 July — found by hand. Two independent causes,
# and this suite is about the second: the per-PR teardown had been failing open
# for months (fixed separately), and even with that fixed, a preview whose PR was
# never opened had nothing at all.
#
# Every case here drives the real script against STUB `modal`, `fly` and `gh`
# commands on PATH, so the sweep's decisions are observable without an account
# and without touching anything live. That matters more than usual for this
# script: its action is destructive, so the only safe way to prove it selects the
# right things is to let it select against a listing we wrote.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

SWEEP="$REPO_ROOT/scripts/sweep-preview-orphans.sh"
SWEEP_SRC="$(cat "$SWEEP" 2>/dev/null)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/bin"
mkdir -p "$STUBS"

# `date -u +%s` inside the script, so the stub listings are written relative to
# now rather than to a frozen clock — a fixture with hardcoded dates silently
# stops testing the grace period as it ages.
NOW="$(date -u +%s)"
OLD_ISO="$(python3 -c "
import datetime, sys
print(datetime.datetime.fromtimestamp(${NOW} - 90 * 3600, datetime.timezone.utc).isoformat())
")"
FRESH_ISO="$(python3 -c "
import datetime, sys
print(datetime.datetime.fromtimestamp(${NOW} - 600, datetime.timezone.utc).isoformat())
")"

# ── Stubs ───────────────────────────────────────────────────────────────────
#
# `gh` returns no open PRs, so nothing is in the allowlist and every decision
# below is made by the age and stack rules alone. That is the harder case: an
# allowlist hit would mask them.
# ⚠️ stub-provenance says `unknown` because that is the honest answer: this stub
# was written from its author's memory of the CLI and has never been compared to
# the real tool. Reading `--version` locally would not change that — it says what
# is installed, not that this response SHAPE was re-recorded against it. Replace
# `unknown` with the version and today's date when you drive the real CLI.
# stub-provenance: gh unknown captured unknown
cat > "$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
echo ""
STUB

# No Fly PREVIEW apps, so the Modal leg has an empty live-stack set — but one
# production app, because the Fly leg now floors on examining zero apps (the org
# holds the production stacks at minimum, so an empty `apps list` is a broken
# listing, not a tidy org). `thestacks-core` does not match the preview pattern,
# so it is counted and then left alone.
# ⚠️ stub-provenance says `unknown` because that is the honest answer: this stub
# was written from its author's memory of the CLI and has never been compared to
# the real tool. Reading `--version` locally would not change that — it says what
# is installed, not that this response SHAPE was re-recorded against it. Replace
# `unknown` with the version and today's date when you drive the real CLI.
# stub-provenance: fly unknown captured unknown
cat > "$STUBS/fly" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"apps list"*) echo '[{"Name": "thestacks-core"}]' ;;
    *"machines list"*) echo "[]" ;;
    *) echo "[]" ;;
esac
STUB

# The Neon leg is now REQUIRED rather than optional, and it reaches the API over
# `curl` — so a `curl` stub stands in for the Neon REST API exactly as the `fly`
# and `modal` stubs stand in for their CLIs. The default listing is one real
# branch (`main`, which no preview pattern matches) so the leg examines a
# non-empty population and sweeps nothing; a DELETE is reported as succeeding.
# Cases that exercise the Neon leg itself redefine this.
# ⚠️ No stub-provenance marker: the provenance gate tracks versioned-output CLIs
# (modal, fly, gh, neon, psql…), and curl here stands in for the Neon REST API,
# whose shape is a property of the API rather than of the curl binary. This stub
# encodes the branches JSON from its author's memory and has never been recorded
# against the live API; the Neon leg is written to fail safe on a key rename
# (missing id/name REFUSES, a missing created_at KEEPS) rather than silently.
cat > "$STUBS/curl" <<STUB
#!/usr/bin/env bash
case "\$*" in
    *"-X DELETE"*) exit 0 ;;
    *"/branches"*) cat <<'JSON'
{"branches": [{"id": "br-main", "name": "main", "created_at": "${OLD_ISO}"}]}
JSON
    ;;
    *) echo "{}" ;;
esac
STUB
chmod +x "$STUBS/curl"

# ✅ stub-provenance VERIFIED, and it is the only one in this repository that is.
# Both JSON key spellings this suite drives were read off the real CLI: 1.2.6
# emitted `Description`/`State`/`Created at` and 1.6.2 emits `description`/
# `state`/`created_at`; and `app stop` was driven on the real account and found
# to PROMPT. That drive is what turned three green-but-false assertions red.
# stub-provenance: modal 1.6.2 captured 2026-10-21
write_modal_stub() {
    local listing="$1"
    cat > "$STUBS/modal" <<STUB
#!/usr/bin/env bash
case "\$*" in
    *"--version"*) echo "modal 9.9.9" ;;
    *"app list"*) cat <<'JSON'
${listing}
JSON
    ;;
    *"app stop"*) echo "stopped \$3" ;;
esac
STUB
    chmod +x "$STUBS/modal"
}

chmod +x "$STUBS/gh" "$STUBS/fly"

run_sweep() {
    (
        cd "$REPO_ROOT" || exit 1
        PATH="$STUBS:$PATH" FLY_API_TOKEN=stub \
            NEON_STAGING_API_KEY=stub NEON_STAGING_PROJECT_ID=stub \
            bash "$SWEEP" "$@" 2>&1
    )
}

test_case "inputs_exist" "the sweep is present and parses"
assert_path_exists "$SWEEP" "scripts/sweep-preview-orphans.sh exists"
if bash -n "$SWEEP" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so it has never run here"
fi

test_case "the_modal_app_name_has_one_definition" \
    "the preview pattern is derived, never written inline"
# A second spelling of the Modal app name here would drift from the deploy that
# creates it. `derive_preview_names` is the single source and has its own suite.
assert_contains "$SWEEP_SRC" 'PREVIEW_MODAL_APP' \
    "the allowlist is built from the derived Modal name"
assert_contains "$(cat "$REPO_ROOT/scripts/lib/preview-names.sh")" \
    'PREVIEW_MODAL_APP="thestacks-vision-${PREVIEW_COMPONENT}"' \
    "and that name is defined in preview-names.sh"

test_case "an_old_orphan_is_selected_and_a_fresh_one_is_kept" \
    "the planted violation, driven against a stub listing"
write_modal_stub "[
  {\"App ID\": \"ap-1\", \"Description\": \"thestacks-vision\", \"State\": \"deployed\",
   \"Tasks\": \"0\", \"Created at\": \"${OLD_ISO}\", \"Stopped at\": null},
  {\"App ID\": \"ap-2\", \"Description\": \"thestacks-vision-long-abandoned\", \"State\": \"deployed\",
   \"Tasks\": \"0\", \"Created at\": \"${OLD_ISO}\", \"Stopped at\": null},
  {\"App ID\": \"ap-3\", \"Description\": \"thestacks-vision-just-deployed\", \"State\": \"deployed\",
   \"Tasks\": \"0\", \"Created at\": \"${FRESH_ISO}\", \"Stopped at\": null}
]"

OUT="$(run_sweep --dry-run)"
RC=$?
if [[ "$RC" -eq 0 ]]; then
    _record_pass "the dry run completed (exit 0)"
else
    _record_fail "the dry run failed: $OUT"
fi

assert_contains "$OUT" "WOULD STOP modal:thestacks-vision-long-abandoned" \
    "an orphan older than the grace period is selected"
assert_contains "$OUT" "KEEP modal:thestacks-vision-just-deployed" \
    "one younger than the grace period is kept"

test_case "production_is_never_selected" "the bare name is not a preview"
# ⛔ The one mistake in this leg that would be unrecoverable. `thestacks-vision`
# is production; a prefix match that accepted it would stop the live vision
# service, and the sweep runs weekly and unattended.
assert_not_contains "$OUT" "WOULD STOP modal:thestacks-vision " \
    "production is not selected"
if grep -qE "(WOULD STOP|STOPPED) modal:thestacks-vision$" <<< "$OUT"; then
    _record_fail "the sweep selected the PRODUCTION vision app"
else
    _record_pass "production is untouched"
fi

test_case "it_counts_what_it_examined" "anti-vacuity on the Modal leg"
assert_contains "$OUT" "Modal apps examined: 3" \
    "the leg reports the size of the population it decided over"

test_case "an_empty_listing_is_a_FAILURE" "a clean sweep over nothing is refused"
# ⛔ Every verdict in this script is a set difference, which is empty when
# everything is tidy AND when nothing was listed. The account holds the
# production app at minimum, so zero examined means a broken listing or parse
# reporting itself as tidy — the shape that let 24 orphans accumulate.
write_modal_stub "[]"
OUT_EMPTY="$(run_sweep --dry-run)"
RC_EMPTY=$?
if [[ "$RC_EMPTY" -ne 0 ]]; then
    _record_pass "an empty Modal listing fails the sweep (exit $RC_EMPTY)"
else
    _record_fail "an empty Modal listing reported a clean sweep: $OUT_EMPTY"
fi
assert_contains "$OUT_EMPTY" "examined 0 Modal apps" \
    "and the failure says what was wrong rather than just failing"

test_case "a_missing_modal_cli_is_a_FAILURE" "not a skip"
# The per-PR teardown swallowed exactly this as "already gone" and reported
# success on every run for months.
rm -f "$STUBS/modal"

# ⛔ Trimming PATH does NOT make Modal absent, and believing it did made this
# case machine-dependent: the sweep falls back to `python3 -m modal`, and a
# module is resolved through the interpreter's site-packages, which PATH has no
# say over. On a developer machine with `modal` pip-installed into the system
# python the fallback SUCCEEDS, the sweep proceeds, and this case fails while
# the script it is testing is perfectly correct. It passed only where modal
# happened not to be installed — a green that was reporting the machine, not
# the code.
#
# So absence is made real: a `python3` stub that fails the module probe and
# delegates everything else to the real interpreter.
cat > "$STUBS/python3" <<'PYSTUB'
#!/usr/bin/env bash
case "$*" in
    *"-m modal"*) exit 1 ;;
esac
exec /usr/bin/python3 "$@"
PYSTUB
chmod +x "$STUBS/python3"

OUT_NOCLI="$(
    cd "$REPO_ROOT" || exit 1
    PATH="$STUBS:/usr/bin:/bin" FLY_API_TOKEN=stub \
        bash "$SWEEP" --dry-run 2>&1
)"
RC_NOCLI=$?
if [[ "$RC_NOCLI" -ne 0 ]]; then
    _record_pass "a missing modal CLI fails the sweep (exit $RC_NOCLI)"
else
    _record_fail "a missing modal CLI was skipped, which is the original defect: $OUT_NOCLI"
fi
assert_contains "$OUT_NOCLI" "modal CLI is not available" \
    "and it names what is missing"

# ⛔ REMOVED, and leaving it behind was a real defect in this suite. The stub
# above delegates with `exec /usr/bin/python3 "$@"`, and `$STUBS` stays first on
# PATH for every case below — so once this case had run, every later `python3`
# in the sweep routed through the stub to the SYSTEM interpreter rather than the
# pinned one, and `BOTH_modal_key_spellings_parse` failed with
# `error: unable to execute tool 'python3'` / "could not list Fly apps".
#
# ⚠️ The shape is what made it hard to see: the failure was ORDER-DEPENDENT, so
# probing `/usr/bin/python3` directly looked fine and the case looked flaky. A
# stub that outlives the case it was built for is a fixture leaking into its
# neighbours — the same class as a probe that outlives its test.
rm -f "$STUBS/python3"

test_case "BOTH_modal_key_spellings_parse" "the CLI renamed its JSON keys once already"
# ⛔ Measured, not hypothetical. Modal 1.2.6 emitted `Description`/`State`/
# `Created at`; 1.6.2 emits `description`/`state`/`created_at`. Against the
# newer CLI the old parser read every field empty, matched no app, swept
# nothing and reported SUCCESS — with a real orphan present.
#
# ⚠️ Neither existing guard could catch it. The anti-vacuity counter counts
# rows EXAMINED and the rows were examined; and this very stub emitted the old
# spelling, so the suite encoded the contract instead of testing it. Both
# spellings are now driven.
for spelling in old new; do
    if [[ "$spelling" == old ]]; then
        write_modal_stub "[
  {\"App ID\": \"ap-1\", \"Description\": \"thestacks-vision-gone\", \"State\": \"deployed\",
   \"Tasks\": \"0\", \"Created at\": \"${OLD_ISO}\", \"Stopped at\": null}
]"
    else
        write_modal_stub "[
  {\"app_id\": \"ap-1\", \"description\": \"thestacks-vision-gone\", \"state\": \"deployed\",
   \"tasks\": \"0\", \"created_at\": \"${OLD_ISO}\", \"stopped_at\": null}
]"
    fi

    OUT_SPELL="$(
        cd "$REPO_ROOT" || exit 1
        PATH="$STUBS:/usr/bin:/bin" FLY_API_TOKEN=stub \
            NEON_STAGING_API_KEY=stub NEON_STAGING_PROJECT_ID=stub \
            bash "$SWEEP" --dry-run 2>&1
    )"
    assert_contains "$OUT_SPELL" "WOULD STOP modal:thestacks-vision-gone" \
        "the ${spelling} key spelling is parsed and the orphan is found"
done

test_case "an_UNREADABLE_modal_row_is_a_REFUSAL" "a renamed key must not read as 'nothing to do'"
# ⛔ The guard the counter could not be. A row whose name cannot be read means
# the listing shape changed; continuing would make every decision below on
# empty strings and collect nothing while exiting 0.
write_modal_stub "[
  {\"app_id\": \"ap-1\", \"totally_renamed_field\": \"thestacks-vision-gone\", \"state\": \"deployed\",
   \"created_at\": \"${OLD_ISO}\"}
]"
OUT_UNREADABLE="$(
    cd "$REPO_ROOT" || exit 1
    PATH="$STUBS:/usr/bin:/bin" FLY_API_TOKEN=stub \
        NEON_STAGING_API_KEY=stub NEON_STAGING_PROJECT_ID=stub \
        bash "$SWEEP" --dry-run 2>&1
)"
RC_UNREADABLE=$?
if [[ $RC_UNREADABLE -ne 0 ]]; then
    _record_pass "an unreadable row fails the sweep (exit $RC_UNREADABLE)"
else
    _record_fail "a listing the sweep could not parse was reported as success: $OUT_UNREADABLE"
fi
assert_contains "$OUT_UNREADABLE" "no readable name" "and the refusal names the cause"
assert_contains "$OUT_UNREADABLE" "reporting" \
    "and says what it would otherwise have done, which is the part worth knowing"

test_case "a_modal_app_follows_its_fly_stack" \
    "the three resources of one preview are decided together"
# ⚠️ Modal reports no last-deploy time, only creation. So a long-lived branch's
# vision app looks ancient however recently it was redeployed, while its Fly
# apps are correctly protected by their newest machine — and without this rule
# the sweep would stop the vision half of a stack it had just called live,
# breaking the upload loop on a preview somebody is using.
write_modal_stub "[
  {\"App ID\": \"ap-1\", \"Description\": \"thestacks-vision\", \"State\": \"deployed\",
   \"Tasks\": \"0\", \"Created at\": \"${OLD_ISO}\", \"Stopped at\": null},
  {\"App ID\": \"ap-2\", \"Description\": \"thestacks-vision-still-working\", \"State\": \"deployed\",
   \"Tasks\": \"0\", \"Created at\": \"${OLD_ISO}\", \"Stopped at\": null}
]"

# A Fly core app for the same component, with a machine created minutes ago —
# so the Fly leg keeps it, and the Modal leg must follow.
cat > "$STUBS/fly" <<STUB
#!/usr/bin/env bash
case "\$*" in
    *"apps list"*) echo '[{"Name": "stacks-core-pr-still-working"}]' ;;
    *"machines list"*) echo '[{"created_at": "${FRESH_ISO}"}]' ;;
    *) echo "[]" ;;
esac
STUB
chmod +x "$STUBS/fly"

OUT_LIVE="$(run_sweep --dry-run)"
assert_contains "$OUT_LIVE" "KEEP stacks-core-pr-still-working" \
    "precondition: the Fly leg keeps the live core app"
assert_contains "$OUT_LIVE" "KEEP modal:thestacks-vision-still-working (its Fly stack is live)" \
    "the Modal app of a live stack is kept despite its creation date"

test_case "a_stopped_modal_app_is_not_acted_on_again" "stop is idempotent by omission"
# Stopping is the only action Modal offers — there is no delete — so an app
# already stopped is in its terminal state. Selecting it again would make every
# run report work it did not do.
write_modal_stub "[
  {\"App ID\": \"ap-1\", \"Description\": \"thestacks-vision\", \"State\": \"deployed\",
   \"Tasks\": \"0\", \"Created at\": \"${OLD_ISO}\", \"Stopped at\": null},
  {\"App ID\": \"ap-2\", \"Description\": \"thestacks-vision-already-stopped\", \"State\": \"stopped\",
   \"Tasks\": \"0\", \"Created at\": \"${OLD_ISO}\", \"Stopped at\": \"${OLD_ISO}\"}
]"
cat > "$STUBS/fly" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"apps list"*) echo '[{"Name": "thestacks-core"}]' ;;
    *"machines list"*) echo "[]" ;;
    *) echo "[]" ;;
esac
STUB
chmod +x "$STUBS/fly"

OUT_STOPPED="$(run_sweep --dry-run)"
assert_not_contains "$OUT_STOPPED" "thestacks-vision-already-stopped" \
    "an already-stopped app is neither selected nor reported"
assert_contains "$OUT_STOPPED" "Modal apps examined: 2" \
    "but it still counts toward the population, so the anti-vacuity check is honest"

test_case "a_FAILED_stop_is_not_counted_as_removed" "the summary must not claim work it did not do"
# ⛔ Measured on the real account, 2026-10-21. Modal 1.6.2's `app stop` PROMPTS
# for confirmation and aborts non-interactively, so the leg had never stopped
# anything — in CI or in any unattended weekly run. The script discarded the
# error, printed a WARN nobody reads, and INCREMENTED the removed count anyway:
# "7 orphan(s) removed" when six were. A sweep that reports work it did not do
# is the exact defect it exists to prevent, reproduced in its own summary.
cat > "$STUBS/modal" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"--version"*) echo "modal 9.9.9" ;;
    *"app list"*) cat <<'JSON'
[{"app_id":"ap-1","description":"thestacks-vision-gone","state":"deployed","created_at":"REPLACE_ISO"}]
JSON
    ;;
    *"app stop"*) echo "Aborted: no interactive terminal detected." >&2; exit 1 ;;
esac
STUB
sed -i.bak "s/REPLACE_ISO/${OLD_ISO}/" "$STUBS/modal" && rm -f "$STUBS/modal.bak"
chmod +x "$STUBS/modal"

OUT_FAILSTOP="$(
    cd "$REPO_ROOT" || exit 1
    PATH="$STUBS:/usr/bin:/bin" FLY_API_TOKEN=stub \
        NEON_STAGING_API_KEY=stub NEON_STAGING_PROJECT_ID=stub \
        bash "$SWEEP" 2>&1
)"
RC_FAILSTOP=$?

if [[ $RC_FAILSTOP -ne 0 ]]; then
    _record_pass "a stop that failed makes the sweep exit non-zero (exit $RC_FAILSTOP)"
else
    _record_fail "the sweep exited 0 having failed to collect an orphan: $OUT_FAILSTOP"
fi
assert_contains "$OUT_FAILSTOP" "FAILED to stop modal:thestacks-vision-gone" \
    "the failure names the app and carries the CLI's own error"
assert_contains "$OUT_FAILSTOP" "0 orphan(s) removed" \
    "and the count reports ZERO removed, not one"
assert_contains "$OUT_FAILSTOP" "1 failed" "with the failure counted separately"

test_case "the_stop_passes_the_confirmation_flag" "non-interactive by construction"
# Without `--yes` the modern CLI aborts in every unattended context, which is
# every context this script runs in.
assert_contains "$SWEEP_SRC" "app stop --yes" \
    "the stop is invoked with --yes, so no prompt can abort it"

# ── The adoption assertion — the actual deliverable ──────────────────────────
#
# Returns, one per line, every destructive call that is NOT on an `attempt`
# line, after FULL-LINE comments are stripped — the explanatory comments name
# all three commands in prose, so an unstripped scan would read them as
# violations. The three tokens are the real command forms: `fly apps destroy`,
# the curl `-X DELETE`, and modal's `app stop`.
destroys_not_wrapped() {
    local src="$1"
    local stripped
    stripped="$(grep -vE '^[[:space:]]*#' <<< "$src")"
    local pat line
    for pat in "fly apps destroy" "-X DELETE" "app stop"; do
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            case "$line" in
                *attempt*) ;;
                *) printf '%s\t%s\n' "$pat" "$line" ;;
            esac
        done < <(grep -F -- "$pat" <<< "$stripped")
    done
}

test_case "every_destroy_goes_through_attempt" "the diagnosis is adopted, not just the one fix"
# ⛔ The actual deliverable. A planted-violation test of `attempt` proves the
# helper, not that three legs call it — and "the fix was adopted, not just the
# diagnosis" is the whole point of this change. No `fly apps destroy`, no
# `curl -X DELETE` and no `modal app stop` may run outside an `attempt`.
UNWRAPPED="$(destroys_not_wrapped "$SWEEP_SRC")"
if [[ -z "$UNWRAPPED" ]]; then
    _record_pass "all three destructive calls are wrapped in attempt"
else
    _record_fail "a destructive call runs outside attempt:
$UNWRAPPED"
fi

# ⛔ Anti-vacuity on the assertion itself: each destroy must be PRESENT on an
# attempt line, or a rename would make the check pass by matching nothing.
for pat in "fly apps destroy" "-X DELETE" "app stop"; do
    WRAPPED="$(grep -vE '^[[:space:]]*#' <<< "$SWEEP_SRC" | grep -F -- "$pat")"
    if grep -q "attempt" <<< "$WRAPPED"; then
        _record_pass "the '${pat}' destroy is present and wrapped — not vacuous for it"
    else
        _record_fail "no wrapped '${pat}' in the sweep — the adoption check matches nothing"
    fi
done

test_case "the_adoption_assertion_can_fire" "a bare destroy outside attempt reddens it"
# The assertion's own floor: inject a bare `fly apps destroy` and show it is
# caught. Without this the check could silently stop catching anything.
TAMPERED="${SWEEP_SRC}
        fly apps destroy \"\$rogue\" --yes"
if [[ -n "$(destroys_not_wrapped "$TAMPERED")" ]]; then
    _record_pass "a bare 'fly apps destroy' outside attempt is caught"
else
    _record_fail "a planted bare destroy was NOT caught — the adoption assertion is vacuous"
fi

# ── Stubs that let the Fly and Neon legs be DRIVEN, not just present ──────────
#
# The suite above drove only the Modal leg: the fly stub returned [] for every
# call and the Neon secrets were empty, so neither leg's selection or destroy
# ran. These write listings the Fly and Neon legs decide against — a production
# app, one preview past the grace period, one inside it — so each leg's four
# guarantees (failure counted as failure, stderr captured, parse/empty refusal,
# absent-secret refusal) are driven, not merely asserted to exist in the source.
benign_fly_stub() {
    cat > "$STUBS/fly" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"apps list"*) echo '[{"Name": "thestacks-core"}]' ;;
    *"machines list"*) echo "[]" ;;
    *) echo "[]" ;;
esac
STUB
    chmod +x "$STUBS/fly"
}

benign_curl_stub() {
    cat > "$STUBS/curl" <<STUB
#!/usr/bin/env bash
case "\$*" in
    *"-X DELETE"*) exit 0 ;;
    *"/branches"*) echo '{"branches": [{"id": "br-main", "name": "main", "created_at": "${OLD_ISO}"}]}' ;;
    *) echo "{}" ;;
esac
STUB
    chmod +x "$STUBS/curl"
}

benign_modal_stub() {
    write_modal_stub "[
  {\"App ID\": \"ap-prod\", \"Description\": \"thestacks-vision\", \"State\": \"deployed\",
   \"Created at\": \"${OLD_ISO}\", \"Stopped at\": null}
]"
}

# A Fly listing with a production app and two previews: one aged past the grace
# period (an orphan) and one inside it (an in-flight CI run). `destroy_line` is
# the body of the `apps destroy` case, so a case can make the destroy succeed or
# fail without a second stub.
write_fly_preview_stub() {
    local destroy_line="$1"
    cat > "$STUBS/fly" <<STUB
#!/usr/bin/env bash
case "\$*" in
    *"apps list"*) echo '[{"Name": "thestacks-core"}, {"Name": "stacks-core-pr-old-orphan"}, {"Name": "stacks-core-pr-fresh-ci"}]' ;;
    *"--app stacks-core-pr-old-orphan"*) echo '[{"created_at": "${OLD_ISO}"}]' ;;
    *"--app stacks-core-pr-fresh-ci"*) echo '[{"created_at": "${FRESH_ISO}"}]' ;;
    *"machines list"*) echo "[]" ;;
    *"apps destroy"*) ${destroy_line} ;;
    *) echo "[]" ;;
esac
STUB
    chmod +x "$STUBS/fly"
}

# A Neon branches listing with the default branch and two previews, same ages.
# `delete_line` is the body of the `-X DELETE` case.
write_curl_branches_stub() {
    local delete_line="$1"
    cat > "$STUBS/curl" <<STUB
#!/usr/bin/env bash
case "\$*" in
    *"-X DELETE"*) ${delete_line} ;;
    *"/branches"*) echo '{"branches": [{"id": "br-main", "name": "main", "created_at": "${OLD_ISO}"}, {"id": "br-old", "name": "preview/old-orphan", "created_at": "${OLD_ISO}"}, {"id": "br-fresh", "name": "preview/fresh-ci", "created_at": "${FRESH_ISO}"}]}' ;;
    *) echo "{}" ;;
esac
STUB
    chmod +x "$STUBS/curl"
}

# ── Fly leg ──────────────────────────────────────────────────────────────────
benign_modal_stub
benign_curl_stub

test_case "the_fly_leg_selects_against_a_written_listing" "an old orphan goes, a fresh one stays"
# ⛔ The Fly leg had NO case driving its selection — the stub returned [] for
# every call, so the age rule was never exercised. Here it lists a production
# app and two previews, one each side of the grace period.
write_fly_preview_stub 'echo destroyed'
OUT_FLY="$(run_sweep)"
RC_FLY=$?
if [[ $RC_FLY -eq 0 ]]; then
    _record_pass "the Fly sweep completed (exit 0)"
else
    _record_fail "the Fly sweep failed: $OUT_FLY"
fi
assert_contains "$OUT_FLY" "DESTROYED stacks-core-pr-old-orphan" \
    "an app older than the grace period is destroyed"
assert_contains "$OUT_FLY" "KEEP stacks-core-pr-fresh-ci (younger than" \
    "one inside the grace period is kept"
assert_contains "$OUT_FLY" "Fly apps examined: 3" \
    "and the leg reports the population it decided over, production app included"
assert_not_contains "$OUT_FLY" "DESTROYED thestacks-core" \
    "the production app is never a target"

test_case "a_FAILED_fly_destroy_is_not_counted_as_removed" "failure counted as failure, stderr kept"
# The two guarantees the Modal leg got and this one did not: a destroy that
# fails must be a FAILURE, not a removal, and its stderr must be carried rather
# than discarded to /dev/null behind a WARN.
write_fly_preview_stub 'echo "machine still has a volume attached" >&2; exit 1'
OUT_FLY_FAIL="$(run_sweep)"
RC_FLY_FAIL=$?
if [[ $RC_FLY_FAIL -ne 0 ]]; then
    _record_pass "a failed Fly destroy makes the sweep exit non-zero (exit $RC_FLY_FAIL)"
else
    _record_fail "the sweep exited 0 having failed to destroy an orphan: $OUT_FLY_FAIL"
fi
assert_contains "$OUT_FLY_FAIL" "FAILED to destroy stacks-core-pr-old-orphan — machine still has a volume attached" \
    "the failure names the app and carries the CLI's own error"
assert_contains "$OUT_FLY_FAIL" "0 orphan(s) removed" \
    "and the count reports ZERO removed, not one"
assert_contains "$OUT_FLY_FAIL" "1 failed" "with the failure counted separately"

test_case "an_empty_fly_listing_is_a_FAILURE" "a clean sweep over zero apps is refused"
# The org holds the production stacks at minimum, so zero examined means a
# broken listing reporting itself as tidy — the Modal leg's floor, for Fly.
cat > "$STUBS/fly" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"apps list"*) echo "[]" ;;
    *) echo "[]" ;;
esac
STUB
chmod +x "$STUBS/fly"
OUT_FLY_EMPTY="$(run_sweep --dry-run)"
RC=$?
if [[ $RC -ne 0 ]]; then
    _record_pass "an empty Fly listing fails the sweep (exit $RC)"
else
    _record_fail "an empty Fly listing reported a clean sweep: $OUT_FLY_EMPTY"
fi
assert_contains "$OUT_FLY_EMPTY" "FAIL sweep (fly)" "and the refusal names the leg"
assert_contains "$OUT_FLY_EMPTY" "examined 0 resources" "and says what was wrong"

test_case "an_unnamed_fly_row_is_a_REFUSAL" "a renamed key must not read as 'nothing to do'"
cat > "$STUBS/fly" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"apps list"*) echo '[{"totally_renamed_field": "stacks-core-pr-gone"}]' ;;
    *) echo "[]" ;;
esac
STUB
chmod +x "$STUBS/fly"
OUT_FLY_UNNAMED="$(run_sweep --dry-run)"
RC=$?
if [[ $RC -ne 0 ]]; then
    _record_pass "an unreadable Fly row fails the sweep (exit $RC)"
else
    _record_fail "a Fly listing the sweep could not parse was reported as success: $OUT_FLY_UNNAMED"
fi
assert_contains "$OUT_FLY_UNNAMED" "FAIL sweep (fly)" "and the refusal names the leg"
assert_contains "$OUT_FLY_UNNAMED" "no readable" "and names the cause"

test_case "the_fly_leg_refuses_without_its_token" "absent secrets are a refusal, not a skip"
OUT_FLY_NOSEC="$(
    cd "$REPO_ROOT" || exit 1
    PATH="$STUBS:$PATH" FLY_API_TOKEN= \
        NEON_STAGING_API_KEY=stub NEON_STAGING_PROJECT_ID=stub \
        bash "$SWEEP" --dry-run 2>&1
)"
RC=$?
if [[ $RC -ne 0 ]]; then
    _record_pass "a missing FLY_API_TOKEN fails the sweep (exit $RC)"
else
    _record_fail "a missing FLY_API_TOKEN was not refused: $OUT_FLY_NOSEC"
fi
assert_contains "$OUT_FLY_NOSEC" "refusal, not a pass" "and says it is a refusal"
assert_contains "$OUT_FLY_NOSEC" "FLY_API_TOKEN" "and names the missing secret"

# ── Neon leg ─────────────────────────────────────────────────────────────────
benign_fly_stub
benign_modal_stub

test_case "the_neon_leg_selects_against_a_written_listing" "an old branch goes, a fresh one stays"
# ⛔ The Neon leg had NO case at all — the suite set NEON_STAGING_API_KEY="", so
# a leg that issues `curl -X DELETE` against real branches was never exercised.
write_curl_branches_stub 'exit 0'
OUT_NEON="$(run_sweep)"
RC_NEON=$?
if [[ $RC_NEON -eq 0 ]]; then
    _record_pass "the Neon sweep completed (exit 0)"
else
    _record_fail "the Neon sweep failed: $OUT_NEON"
fi
assert_contains "$OUT_NEON" "DELETED neon branch preview/old-orphan" \
    "a branch older than the grace period is deleted"
assert_contains "$OUT_NEON" "KEEP neon:preview/fresh-ci (younger than" \
    "one inside the grace period is kept"
assert_not_contains "$OUT_NEON" "DELETED neon branch main" \
    "the project's default branch is never a target"

test_case "a_FAILED_neon_delete_is_not_counted_as_removed" "failure counted as failure, stderr kept"
write_curl_branches_stub 'echo "neon API: 423 branch is protected" >&2; exit 22'
OUT_NEON_FAIL="$(run_sweep)"
RC_NEON_FAIL=$?
if [[ $RC_NEON_FAIL -ne 0 ]]; then
    _record_pass "a failed Neon delete makes the sweep exit non-zero (exit $RC_NEON_FAIL)"
else
    _record_fail "the sweep exited 0 having failed to delete a branch: $OUT_NEON_FAIL"
fi
assert_contains "$OUT_NEON_FAIL" "FAILED to delete neon branch preview/old-orphan — neon API: 423 branch is protected" \
    "the failure names the branch and carries the API's own error"
assert_contains "$OUT_NEON_FAIL" "0 orphan(s) removed" \
    "and the count reports ZERO removed, not one"
assert_contains "$OUT_NEON_FAIL" "1 failed" "with the failure counted separately"

test_case "an_empty_neon_listing_is_a_FAILURE" "a clean sweep over zero branches is refused"
# A Neon project always holds its default branch, so zero branches is a broken
# listing — the same floor, for Neon.
cat > "$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"/branches"*) echo '{"branches": []}' ;;
    *) echo "{}" ;;
esac
STUB
chmod +x "$STUBS/curl"
OUT_NEON_EMPTY="$(run_sweep --dry-run)"
RC=$?
if [[ $RC -ne 0 ]]; then
    _record_pass "an empty Neon listing fails the sweep (exit $RC)"
else
    _record_fail "an empty Neon listing reported a clean sweep: $OUT_NEON_EMPTY"
fi
assert_contains "$OUT_NEON_EMPTY" "FAIL sweep (neon)" "and the refusal names the leg"
assert_contains "$OUT_NEON_EMPTY" "examined 0 resources" "and says what was wrong"

test_case "an_unnamed_neon_row_is_a_REFUSAL" "a renamed key must not read as 'nothing to do'"
cat > "$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"/branches"*) echo '{"branches": [{"totally_renamed": "x", "created_at": "2020-01-01T00:00:00"}]}' ;;
    *) echo "{}" ;;
esac
STUB
chmod +x "$STUBS/curl"
OUT_NEON_UNNAMED="$(run_sweep --dry-run)"
RC=$?
if [[ $RC -ne 0 ]]; then
    _record_pass "an unreadable Neon row fails the sweep (exit $RC)"
else
    _record_fail "a Neon listing the sweep could not parse was reported as success: $OUT_NEON_UNNAMED"
fi
assert_contains "$OUT_NEON_UNNAMED" "FAIL sweep (neon)" "and the refusal names the leg"
assert_contains "$OUT_NEON_UNNAMED" "no readable" "and names the cause"

test_case "the_neon_leg_refuses_without_its_secrets" "absent secrets are a refusal, not a skip"
# ⛔ The headline change: the leg that used to print `SKIP:` and exit 0 now
# refuses, so a run that cannot see Neon stops rather than reporting a clean
# sweep over a class it never looked at.
benign_fly_stub
OUT_NEON_NOSEC="$(
    cd "$REPO_ROOT" || exit 1
    PATH="$STUBS:$PATH" FLY_API_TOKEN=stub \
        NEON_STAGING_API_KEY= NEON_STAGING_PROJECT_ID= \
        bash "$SWEEP" --dry-run 2>&1
)"
RC=$?
if [[ $RC -ne 0 ]]; then
    _record_pass "missing Neon secrets fail the sweep (exit $RC)"
else
    _record_fail "missing Neon secrets were skipped, which is the original defect: $OUT_NEON_NOSEC"
fi
assert_contains "$OUT_NEON_NOSEC" "FAIL sweep (neon)" "and the refusal names the leg"
assert_contains "$OUT_NEON_NOSEC" "NEON_STAGING_API_KEY" "and names the missing secret"
assert_not_contains "$OUT_NEON_NOSEC" "SKIP:" "and it is a refusal, not the old skip"

summarise
