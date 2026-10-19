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
cat > "$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
echo ""
STUB

# No Fly preview apps, so the Modal leg has an empty live-stack set.
cat > "$STUBS/fly" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"apps list"*) echo "[]" ;;
    *"machines list"*) echo "[]" ;;
    *) echo "[]" ;;
esac
STUB

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
            NEON_STAGING_API_KEY="" NEON_STAGING_PROJECT_ID="" \
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
if printf '%s\n' "$OUT" | grep -qE "(WOULD STOP|STOPPED) modal:thestacks-vision$"; then
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
OUT_NOCLI="$(
    cd "$REPO_ROOT" || exit 1
    # An empty PATH but for the stubs, so neither a `modal` binary nor a python3
    # carrying the module can be found.
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
    *"apps list"*) echo "[]" ;;
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

summarise
