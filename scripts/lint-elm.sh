#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Generate proto Elm decoders (required before elm-review can compile)
if [[ -f "$REPO_ROOT/scripts/gen-elm-proto.sh" ]]; then
    bash "$REPO_ROOT/scripts/gen-elm-proto.sh"
fi

# E2E test-suite integrity: no vacuous `if ((await …count()) > 0)` assertion
# guards (Issue #275). Cheap static grep; runs here so `just ci` (elm group) and
# the CI lint-elm job both enforce it.
bash "$REPO_ROOT/scripts/check-e2e-vacuous-guards.sh"

# Negative Elm assertions that cannot do their job (Issue #302). Sibling of the E2E guard check
# above: that one catches `if (count > 0)` wrappers in Playwright specs, this one catches
# `hasNot [ Selector.text "..." ]` that either matches nothing (can never fail) or is a strict
# substring of other rendered copy (can bind to the wrong element). Two real instances motivated it,
# including a SECURITY assertion disarmed by a one-word copy edit.
bash "$REPO_ROOT/scripts/check-prose-assertions.sh"

# Markup naming a style that does not exist (Issue #301). A ratchet, not a backlog gate: it fails only
# when the orphan count RISES, so the existing 398 do not block anyone while a NEW unstyled component
# cannot land. No test can catch this class — the class IS in the DOM, so `Selector.class` passes.
bash "$REPO_ROOT/scripts/check-orphan-classes.sh"

# Admin call sites bypassing the admin-token resolver (Issue #309). Same reason as the two checks
# above: no Elm test can catch it. Measured, not assumed — reintroducing the #303 half-wiring defect
# at one update site left all 1285 Elm tests green, because every page-level admin test receives the
# token as an argument and so cannot notice that `Main` chose the wrong one.
bash "$REPO_ROOT/scripts/check-admin-token-routing.sh"

# Pages that make an authenticated Api call and drop the 401 (Issue #361). Same family again,
# and the sharpest instance of it: there WAS an Elm test for this contract, green for four
# months, listing eight pages by hand while three settings write-forms told readers to "try
# again" against a session that no longer existed. The roster here is a set difference over
# Api.elm × src/Page/, so a page is covered the day it is written. Measured: unwiring the
# `onExpired` handler on Settings/Password reintroduces the defect verbatim and leaves all
# 1427 Elm tests passing.
bash "$REPO_ROOT/scripts/check-session-expiry-coverage.sh"

# Elm ports must be wired on the JS side (Issue #366). An outbound `Cmd` port with
# no `app.ports.X.subscribe` drops its command silently — `saveOnboardingCompleted`
# did exactly that (#395), so finishing onboarding never persisted. Also fails a JS
# `app.ports.X` naming a port Elm does not declare (a typo that throws at runtime).
bash "$REPO_ROOT/scripts/check-ports-wired.sh"

# The stylesheet itself (Issue #306). Nothing in this gate looked at main.css before — not its syntax,
# not its specificity. Three defects shipped through a green `just verify` in one change on
# 2026-07-29, including CSS a browser cannot parse. Checks well-formedness, bans `[class*=]`
# selectors, and refuses a modifier whose state a base `:hover` rule silently overrides.
bash "$REPO_ROOT/scripts/check-css.sh"

# The stylesheet's token VALUES (Issue #319, Wave 9c). The third CSS gate, sibling to the two above:
# check-orphan-classes.sh governs which classes exist, check-css.sh governs their structure, and this
# one governs the VALUES a declaration uses. It fails on drift a browser and every test render blind
# to — a bare hex equal to a token's value (should have been the var()), a var() of an undefined
# token, a fallback that disagrees with the token's definition, and a spacing literal equal to a
# --space-* step. Each dimension is an itemised ratchet at its current count (colour/var/fallback are
# the theme-varying residuals 9b left; spacing is greenfield), so a NEW violation fails while today's
# known residuals do not.
bash "$REPO_ROOT/scripts/check-css-values.sh"

(cd frontend && npx elm-format --validate src/)
(cd frontend && npm audit)

# elm-review: NoUnused rules
if command -v npx &>/dev/null && (cd "$REPO_ROOT/frontend" && npx --yes elm-review --version &>/dev/null 2>&1); then
    (cd "$REPO_ROOT/frontend" && npx elm-review --config elm-review src/ tests/)
else
    echo "SKIP: elm-review not installed (npm install -g elm-review)"
fi
