#!/usr/bin/env bash
#
# Proves the tracker-reference gate can fail, and — more importantly — proves
# it does not fire on the things that would get it disabled.
#
# Two things make this suite necessary rather than ceremonial.
#
# First, the gate's own first version was structurally unable to catch the
# violation it was written for. Its hex-colour guard was `^#[0-9a-fA-F]{3,8}$`,
# which matches `#412` — 4, 1 and 2 are all valid hex digits — so every
# all-digit issue number of length 3, 6 or 8 read as a colour and passed. The
# gate ran green on a planted `#412` and looked like it worked. A hand-run red
# check happened to catch that; nothing would have caught it coming back.
#
# Second, the gate's input is `git ls-files`, so it cannot be exercised by
# editing files in this repo: a planted violation would have to be committed to
# be seen. Every case here therefore builds a THROWAWAY GIT REPO in a tmpdir,
# commits the planted file into it, and runs the gate with that repo as its
# root. The gate resolves its own root via `git rev-parse --show-toplevel`,
# which is what makes this possible.
#
# The false-positive half is not padding. A gate that fires on a hex colour or
# a CSS custom property gets suppressed within a week, and a suppressed gate is
# worse than no gate because it also carries a claim.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-tracker-refs.sh"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
LINT_ELIXIR="$REPO_ROOT/scripts/lint-elixir.sh"

SANDBOX=""
cleanup() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}
trap cleanup EXIT

# Runs the gate over a sandbox repo containing exactly one file.
#
#   run_on <relative path> <file contents>
#
# Sets GATE_OUT and GATE_RC. Each call gets a fresh repo, so no case can leak
# into the next — which matters because the gate reports every violation it
# finds and a leaked one would satisfy the wrong assertion.
run_on() {
    local rel_path="$1"
    local contents="$2"

    cleanup
    SANDBOX="$(mktemp -d)"
    mkdir -p "$SANDBOX/$(dirname "$rel_path")"
    printf '%s\n' "$contents" > "$SANDBOX/$rel_path"

    git -C "$SANDBOX" init --quiet
    git -C "$SANDBOX" add --all
    # Committing is not needed — the gate reads the index via `git ls-files` —
    # but an `init` with no commit makes `rev-parse --show-toplevel` fragile on
    # some git versions, so stage and commit for determinism.
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit --quiet -m t

    GATE_OUT="$(cd "$SANDBOX" && bash "$GATE" 2>&1)"
    GATE_RC=$?
}

# Same, but leaves the file UNTRACKED.
run_on_untracked() {
    local rel_path="$1"
    local contents="$2"

    cleanup
    SANDBOX="$(mktemp -d)"
    mkdir -p "$SANDBOX/$(dirname "$rel_path")"
    git -C "$SANDBOX" init --quiet
    printf 'placeholder\n' > "$SANDBOX/placeholder.txt"
    git -C "$SANDBOX" add placeholder.txt
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit --quiet -m t
    printf '%s\n' "$contents" > "$SANDBOX/$rel_path"

    GATE_OUT="$(cd "$SANDBOX" && bash "$GATE" 2>&1)"
    GATE_RC=$?
}

test_case "gate_exists" "the script both callers invoke is present"
assert_path_exists "$GATE" "scripts/check-tracker-refs.sh exists"

test_case "clean_repo_passes" "a file citing nothing passes"
run_on "apps/core/lib/thing.ex" '# The cap belonged to the review-summary caller and was corrupting the other.'
assert_exit_zero "$GATE_RC" "a substantive comment is not a violation"
assert_contains "$GATE_OUT" "OK: no tracker references" "it reports the pass"

# ———————————————————————— violations ————————————————————————
# Each must fail, AND must name its own pattern. Asserting only the exit code
# would be satisfied by a missing script (bash exits 127) or by a crash.

test_case "adr_id" "an ADR id in a comment fails"
run_on "apps/core/lib/thing.ex" '# Superseded by ADR-015, which replaced the two-call shape.'
assert_exit_nonzero "$GATE_RC" "ADR-015 is a violation"
assert_contains "$GATE_OUT" "an ADR / decision-record id" "it names the pattern"
assert_contains "$GATE_OUT" "ADR-015" "it quotes what it matched"

test_case "decision_id" "the 'Decision NNN' spelling also fails"
run_on "apps/core/lib/thing.ex" '# Kept per Decision 015.'
assert_exit_nonzero "$GATE_RC" "Decision 015 is the same citation in other words"
assert_contains "$GATE_OUT" "an ADR / decision-record id" "it names the pattern"

test_case "user_story_id" "a user-story id fails"
run_on "frontend/src/Page/Thing.elm" '-- Implements US-1.4.1 acceptance criterion 3.'
assert_exit_nonzero "$GATE_RC" "US-1.4.1 is a violation"
assert_contains "$GATE_OUT" "a user-story id" "it names the pattern"

test_case "tracker_path" "a path into issues/ fails"
run_on "scripts/thing.sh" '# Background in issues/279-the-thing.md'
assert_exit_nonzero "$GATE_RC" "issues/279 is a violation"
assert_contains "$GATE_OUT" "a path into issues/ or plans/" "it names the pattern"

test_case "issue_number_all_digits" "an ALL-DIGIT issue number fails — the regression case"
# ⚠️ This is the case the gate's first hex guard swallowed. `#412` is valid hex
# of length 3, so `^#[0-9a-fA-F]{3,8}$` matched it and the violation passed.
# If this assertion ever goes green-by-passing again, the discriminator has
# been rewritten back to a syntactic one.
run_on "apps/core/lib/thing.ex" '# See #412 for the rationale.'
assert_exit_nonzero "$GATE_RC" "#412 is an issue citation, not a colour"
assert_contains "$GATE_OUT" "an issue number" "it names the pattern"
assert_contains "$GATE_OUT" "#412" "it quotes what it matched"

test_case "issue_number_six_digits" "a six-digit citation fails too"
run_on "apps/core/lib/thing.ex" '# Tracked as #183020 upstream.'
assert_exit_nonzero "$GATE_RC" "six digits is also a hex-valid length and must not be excused"

test_case "campaign_slug" "a campaign slug fails"
run_on "apps/vision/app/thing.py" '# Part of staff-campaign-2026-10-13 wave work.'
assert_exit_nonzero "$GATE_RC" "a campaign slug is a violation"
assert_contains "$GATE_OUT" "a campaign slug" "it names the pattern"

test_case "wave_label" "a keyed wave label fails"
run_on "apps/core/lib/thing.ex" '# Deferred to W2h.'
assert_exit_nonzero "$GATE_RC" "a wave label is a violation"
assert_contains "$GATE_OUT" "a wave label" "it names the pattern"

test_case "wave_label_spelled_out" "the SPELLED-OUT wave label fails — the form this repo writes"
# ⚠️ The regression case for the pattern set's own blind spot. `W2h` is how the
# campaign STATE FILE keys items; code prose says "Wave 8 moved the five shelf
# links". Claiming only the keyed form left SEVEN live violations standing
# behind a green gate, in a justfile, two e2e specs, a shell script, a Python
# docstring and an Elixir output string. A pattern set derived from the
# violations in hand is not a pattern set derived from how people write.
run_on "e2e/tests/thing.spec.ts" '// Wave 8 moved the five shelf links.'
assert_exit_nonzero "$GATE_RC" "the spelled-out form is the same citation"
assert_contains "$GATE_OUT" "a wave label" "it names the pattern"

test_case "decision_record_path" "a decision record cited as a PATH fails"
# The `ADR[ -]\d` pattern only sees the id spelling, so `See docs/decisions/017.`
# sailed past — in a protobuf contract comment, the same file type and the same
# class this gate was filed over.
run_on "proto/thing.proto" '// See docs/decisions/017.'
assert_exit_nonzero "$GATE_RC" "a path to a decision record is a citation"
assert_contains "$GATE_OUT" "a decision record or user story" "it names the pattern"

test_case "phase_label_is_not_claimed" "'Phase 1' passes — it has a second, honest meaning"
# The deliberate non-claim, and the contrast that justifies claiming "Wave".
# `view_as_plug` documents its own two-step design as "Phase 1 (plug)" /
# "Phase 2 (authorize)"; roughly fifty such lines are modules describing
# themselves, not citations. "Wave" has no second meaning in this tree.
run_on "apps/core/lib/thing.ex" '# Phase 1 parses the param; Phase 2 checks ownership.'
assert_exit_zero "$GATE_RC" "a design phase is not a campaign phase"

test_case "bare_campaign_name_is_not_claimed" "the UNDATED campaign phrase passes"
# The claim boundary for campaign names is the DATE. A dated slug names one
# particular campaign and ages into a dead end; the bare phrase is a tool
# naming its own subject matter — `just wave-status`'s help text asks "Is a
# staff-campaign wave actually done?" and rewording that would make the help
# worse, not the code better.
run_on "justfile" '# Is a staff-campaign wave actually done? Reads the state file.'
assert_exit_zero "$GATE_RC" "the undated phrase is a domain word, not a citation"

test_case "dated_campaign_slug_still_fails" "the DATED slug still fails"
run_on "apps/core/lib/thing.ex" '# Part of staff-campaign-2026-10-13.'
assert_exit_nonzero "$GATE_RC" "the dated form names one campaign and is a citation"

test_case "standards_path_is_not_claimed" "a docs/agents/ standards path passes"
# Also deliberate, and awaiting an owner ruling rather than settled: a
# resolving repo-relative path to a STANDARD is arguably better than prose,
# because a gate can check that the file still exists where a prose assertion
# cannot. Claiming it would break three live citations that point at testing
# and dashboard standards. If the ruling goes the other way, this case is the
# thing to delete first.
run_on "scripts/thing.sh" '# See docs/agents/standards/testing.md for the rule.'
assert_exit_zero "$GATE_RC" "standards paths are out of scope pending a ruling"

test_case "trailing_comment" "a citation in a TRAILING comment fails"
# The leading-comment case is the easy one. A trailing `# see #412` after real
# code is the shape that reads as a value position to a naive check.
run_on "apps/core/lib/thing.ex" 'do_the_thing()  # see #412'
assert_exit_nonzero "$GATE_RC" "a trailing comment is still a comment"
assert_contains "$GATE_OUT" "an issue number" "it names the pattern"

# ———————————————————— false positives ————————————————————
# Each of these must PASS. Any one of them firing is what gets the gate turned
# off, so they are load-bearing in the opposite direction.

test_case "hex_colour_with_letter" "a hex colour containing a letter passes"
# ⚠️ This case USED TO PASS FOR THE WRONG REASON, and the correction is the
# point. Its old comment credited a `HAS_HEX_LETTER` guard inside the gate —
# but the only pattern that can produce a `#`-leading match is `#\d{3,}`, which
# is digits only, so `#1a2b3c` was never matched by anything and the guard was
# unreachable. Deleting the guard left this green. The guard is gone; the real
# property is that the citation pattern is digit-only, which the next case
# pins from the other side.
run_on "frontend/css/main.css" '.thing { color: #1a2b3c; }'
assert_exit_zero "$GATE_RC" "a letter-bearing hex is not matched by a digit-only citation pattern"

test_case "hex_colour_with_letter_outside_a_stylesheet" "and it passes in a .ex file too"
# The half that makes the previous case meaningful: if the citation pattern were
# ever widened to `[0-9a-fA-F]`, THIS would start failing, because nothing
# outside a stylesheet value position gets the colour excusal. It is the
# tripwire on that widening.
run_on "apps/core/lib/thing.ex" 'colour = "#1a2b3c"'
assert_exit_zero "$GATE_RC" "the pattern claims digits, so a letter-bearing token is out of scope entirely"

test_case "hex_colour_all_digits" "an ALL-DIGIT hex colour in a value position passes"
# The other side of the discriminator. `#183020` is a real gradient stop in
# this project's stylesheet and is syntactically identical to a citation; only
# its position separates them.
run_on "frontend/css/main.css" '.thing { background: #183020; }'
assert_exit_zero "$GATE_RC" "an all-digit colour in a declaration value is not a citation"

test_case "css_custom_property" "a CSS custom property is not read as a comment"
# `--` opens a comment in Elm and SQL but declares a custom property in CSS.
# Treating it as a comment lead marked every themed colour in main.css a
# citation.
#
# ⚠️ The declaration must be on its OWN LINE, which is how it is written in
# main.css. The first version of this case wrote the whole block on one line —
# `:root { --wallpaper-color: #253040; }` — and that line begins with `:`, so
# nothing reached the `--` branch at all. Disabling the CSS carve-out entirely
# left this case green, which is how the hole was found: the case asserted the
# right thing about the wrong input.
run_on "frontend/css/main.css" ':root {
    --wallpaper-color: #253040;
}'
assert_exit_zero "$GATE_RC" "a custom property holding an all-digit colour passes"

test_case "citation_beside_an_excused_colour" "a citation AFTER an excused colour on the same line fails"
# ⚠️ The fail-open that `search` created and `finditer` closes. The scan used to
# take only the first match per line; when that match was excused as a colour it
# moved on to the next PATTERN, so everything after it on the line was never
# looked at. This exact line passed.
run_on "frontend/css/main.css" '    --wallpaper-color: #253040; /* see #412 */'
assert_exit_nonzero "$GATE_RC" "excusing one match must not excuse the rest of the line"
assert_contains "$GATE_OUT" "#412" "it reports the citation, not the colour"

test_case "git_sha" "a commit sha in a comment passes"
run_on "apps/core/lib/thing.ex" '# Behaviour changed in db0d0bcc; the old shape is gone.'
assert_exit_zero "$GATE_RC" "a sha is an acceptable pointer and must not trip the gate"

test_case "date_and_isbn" "a date and an ISBN pass"
run_on "apps/core/lib/thing.ex" '# Ruled 2026-10-15. Fixture ISBN 9780141988511.'
assert_exit_zero "$GATE_RC" "neither a date nor an ISBN is a tracker id"

test_case "proto_field_number" "a proto field number passes"
run_on "proto/thing.proto" '  repeated MyWritingSummary my_writing = 8;'
assert_exit_zero "$GATE_RC" "field numbers are not citations"

test_case "bare_words" "bare 'ADR' and 'US' pass"
run_on "apps/core/lib/thing.ex" '# The ADR process and the US market are both fine to mention.'
assert_exit_zero "$GATE_RC" "the patterns require the id form, not the word"

test_case "two_digit_hash" "a two-digit #NN passes"
# Deliberately not claimed: too noisy. Asserting it keeps a future widening
# honest — if someone lowers the threshold, this case tells them what they are
# buying rather than letting the noise appear in unrelated diffs.
run_on "apps/core/lib/thing.ex" '# Column #12 in the fixture.'
assert_exit_zero "$GATE_RC" "two digits is below the threshold the gate claims"

# ———————————————————————— scope ————————————————————————

test_case "markdown_excluded" "a citation in a *.md file passes"
run_on "apps/core/NOTES.md" 'Superseded by ADR-015, see issues/279.'
assert_exit_zero "$GATE_RC" "documentation cites decision records legitimately"

test_case "docs_dir_excluded" "a citation anywhere under docs/ passes"
run_on "docs/thing.txt" 'Superseded by ADR-015.'
assert_exit_zero "$GATE_RC" "docs/ is out of scope by design, whatever the extension"

test_case "untracked_not_scanned" "an untracked file is not scanned"
# Not a nicety: it is why the gate ran clean on itself until it was committed.
# A clean first run of any new file-scanning gate proves less than it looks.
run_on_untracked "apps/core/lib/thing.ex" '# See #412.'
assert_exit_zero "$GATE_RC" "the gate reads tracked files only"

test_case "tooling_path_exempt" "issue-management tooling may name the trees it manages"
run_on "scripts/wave-status.sh" 'LEDGER="plans/residue-ledger.md"'
assert_exit_zero "$GATE_RC" "a path a tool OPERATES on is not a citation"

test_case "tooling_exemption_is_narrow" "the exemption does not cover ordinary scripts"
run_on "scripts/deploy-thing.sh" 'LEDGER="plans/residue-ledger.md"'
assert_exit_nonzero "$GATE_RC" "a script not in the tooling list gets no exemption"

test_case "fixture_exemption_is_narrow" "another test file citing a tracker still fails"
# THIS suite is exempt, because its content is planted violations. That
# exemption must not generalise to "tests may cite trackers" — a test name
# carrying an issue number is precisely what the rule forbids, and the hook
# that enforces the rule by hand has caught it in test names before.
run_on "test/platform/some_other_test.sh" 'test_case "regression" "covers #412"'
assert_exit_nonzero "$GATE_RC" "the fixture exemption is one file, not a directory"

# ———————————————————————— callers ————————————————————————
# A gate nothing invokes is not a gate. This project has shipped one.

test_case "caller_ci" "the CI workflow invokes the gate"
if [[ -f "$CI_YML" ]]; then
    assert_contains "$(cat "$CI_YML")" "scripts/check-tracker-refs.sh" \
        "ci.yml runs the gate"
else
    _record_fail "ci.yml not found at $CI_YML"
fi

test_case "caller_lint" "the local lint runner invokes the gate"
if [[ -f "$LINT_ELIXIR" ]]; then
    assert_contains "$(cat "$LINT_ELIXIR")" "check-tracker-refs.sh" \
        "lint-elixir.sh runs the gate, so it fires before CI does"
else
    _record_fail "lint-elixir.sh not found at $LINT_ELIXIR"
fi

summarise
exit $?
