# Dialyzer ignore filters — deliberately EMPTY.
#
# `mix dialyzer` runs in :dev (see scripts/lint-elixir.sh; `preferred_envs` in
# mix.exs does not list dialyzer). In :dev, `elixirc_paths/1` is ["lib"], so
# test/support/ is never compiled and dialyzer reports **0 errors with nothing
# suppressed**. That is the state to keep: every warning is real and none is
# hidden behind a filter.
#
# `list_unused_filters: true` in mix.exs halts on any filter that matches
# nothing, which keeps this list honest — and is what made the file's previous
# contents fail the build.
#
# ## Why the ExUnit filter was removed (2026-07-28)
#
# It read `~r/Function ExUnit\./` and was documented as "the only necessary
# entry", absorbing 7 warnings such as
# `Function ExUnit.Callbacks.__merge__/4 does not exist.` Those warnings only
# arise under MIX_ENV=test, where elixirc_paths includes test/support/ and
# dialyzer cannot resolve ExUnit's internals. Issue #300 baselined the file in
# :test (its notes cite a `deps-test.plt`) while the gate runs :dev — so the
# filter matched nothing where it actually ran, `list_unused_filters` halted,
# and `just verify` failed for everyone with `Total errors: 0`.
#
# Worth knowing if anyone moves dialyzer to :test: the filter did not work there
# either. Under MIX_ENV=test it reported `Total errors: 7, Skipped: 0` — the
# regex never matched those warnings. Analysing test/support/ buys nothing but
# unresolvable ExUnit internals, so :dev is the right env and this file should
# stay empty.
#
# Previously removed for Issue #300 (all six matched zero warnings on OTP 28;
# re-add with a fresh justification if an OTP/dep bump reintroduces one):
#
#   ~r/Function NimbleTOTP\./
#   ~r/Unknown type: NimbleTOTP\./
#   ~r/Unknown type: Stacks\.AdminSession\.t/
#   ~r/Unknown type: Stacks\.MFA\.UserMFA\.t/
#   ~r/admin_auth_controller\.ex.*pattern_match_cov/
#   ~r/Postgrex\.Extensions\.Interval\./
[]
