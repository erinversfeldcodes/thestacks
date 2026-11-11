#!/usr/bin/env bash
# test/platform/exclusion_tags_have_runners_test.sh
#
# An ExUnit tag in the default EXCLUDE list is a promise that some runner
# selects it. When nothing does, those tests never execute anywhere — and
# nothing says so, because an excluded test is reported as excluded rather than
# as missing.
#
# This is not hypothetical. Eight tests in `upload_dbt_test.exs` were tagged
# `:deployed_only` and asserted on a warehouse they could never see; the only
# selector for that tag is `scripts/test-deployed.sh`, and a wiring sweep found
# that script had no caller at all. So the tests were excluded by default,
# unreachable by
# the one runner that named them, and carried a failure message blaming a cause
# that could not have fixed them. The first time they ran, two of them failed —
# one on a precondition and one on a real defect (a raw binary uuid compared to
# a string) that had been sitting there unseen.
#
# ⚠️ The general shape: **a tag is a claim about what a test needs, and nothing
# checks the claim.** This repo also carries `suite: :dbt` on 51 tests that no
# runner selects on — harmless, because that tag excludes nothing, but the same
# species. This suite governs the severe case, where the tag decides whether the
# test runs at all.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

TEST_HELPER="$REPO_ROOT/apps/core/test/test_helper.exs"

test_case "inputs_exist" "the ExUnit configuration is present"
assert_path_exists "$TEST_HELPER" "apps/core/test/test_helper.exs exists"

# The tags inside `ExUnit.configure(exclude: [...])`. Read from the file rather
# than listed here, so adding an exclusion without a runner reddens this suite
# instead of silently hiding a test module.
EXCLUDED="$(
    python3 - "$TEST_HELPER" <<'PY'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
# Strip comments first: this file explains the tags at length, and the prose
# names them, so a naive match reads the explanation as configuration.
code = "\n".join(
    line for line in src.splitlines() if not line.lstrip().startswith("#")
)
m = re.search(r"ExUnit\.configure\(\s*exclude:\s*\[(.*?)\]", code, re.DOTALL)
if not m:
    raise SystemExit(0)
for tag in re.findall(r":([a-z_][a-z0-9_]*)", m.group(1)):
    print(tag)
PY
)"

test_case "exclusions_readable" "the exclude list can be read"
if [[ -z "$EXCLUDED" ]]; then
    _record_fail "no excluded tags found in test_helper.exs — either the list is gone or the parse broke; both mean this suite is asserting nothing"
else
    _record_pass "found excluded tag(s): $(printf '%s' "$EXCLUDED" | tr '\n' ' ')"
fi

# Anywhere a runner could select a tag: shell scripts, workflows, the justfile.
SELECTOR_CORPUS="$(
    cat \
        "$REPO_ROOT"/scripts/*.sh \
        "$REPO_ROOT"/.github/workflows/*.yml \
        "$REPO_ROOT/justfile" \
        2>/dev/null
)"

test_case "every_exclusion_has_a_runner" "a tag that hides tests has something that runs them"
while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    # ⚠️ Bash's own substring test, not grep, and both spellings.
    #
    # Two earlier versions of this line reported EVERY tag as unselected while
    # the anti-vacuity assertion below — which uses exactly this construct —
    # passed on the same variable. First `grep -E "…\b"` (BSD grep, this
    # project's system grep, does not support `\b` in ERE), then
    # `grep -qF -- "--only …"`, where the pattern's own leading dashes are the
    # problem. Two mechanisms disagreeing about one string is what exposed it,
    # which is the whole reason that assertion is there.
    if [[ "$SELECTOR_CORPUS" == *"--only ${tag}"* ||
        "$SELECTOR_CORPUS" == *"--only=${tag}"* ]]; then
        _record_pass "the :${tag} exclusion is selected by a runner (--only ${tag})"
    else
        _record_fail "nothing selects :${tag} — tests carrying it are excluded by default and run NOWHERE. Add a runner that passes \`--only ${tag}\`, or delete the exclusion so they run with everything else."
    fi
done <<<"$EXCLUDED"

# Anti-vacuity. The loop above passes trivially if the corpus is empty or the
# grep pattern stops matching, and both are one edit away.
test_case "the_selector_corpus_is_real" "the search actually read the runners"
assert_contains "$SELECTOR_CORPUS" "--only deployed_only" \
    "scripts/test-deployed.sh's known selector must be visible to this search, or the search is not reading the runners it claims to"

summarise
