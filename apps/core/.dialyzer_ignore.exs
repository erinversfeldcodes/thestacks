# Dialyzer ignore filters — re-baselined empirically on OTP 28 / Elixir 1.18.4
# for Issue #300 (local and CI now share the flake's OTP-28 toolchain, so the
# warning set is finally identical). `list_unused_filters: true` in mix.exs
# halts if any filter here is unnecessary, keeping this list honest — the six
# filters below were removed because an OTP-28 `mix dialyzer` skips nothing
# through them (each was an "Unnecessary Skip", matching zero warnings):
#
#   ~r/Function NimbleTOTP\./                         — no longer emitted on OTP 28
#   ~r/Unknown type: NimbleTOTP\./                    — no longer emitted on OTP 28
#   ~r/Unknown type: Stacks\.AdminSession\.t/         — no longer emitted on OTP 28
#   ~r/Unknown type: Stacks\.MFA\.UserMFA\.t/         — no longer emitted on OTP 28
#   ~r/admin_auth_controller\.ex.*pattern_match_cov/  — no longer emitted on OTP 28
#   ~r/Postgrex\.Extensions\.Interval\./              — no longer emitted on OTP 28
#
# If a future OTP/dep bump reintroduces one of these, dialyzer will flag the
# real warning — re-add the specific filter then, with a fresh justification.
#
# Kept (needed on OTP 28):
# With MIX_ENV=test, elixirc_paths includes test/support/ — dialyzer checks the
# compiled beams but can't resolve ExUnit's internal functions. This filter
# absorbs those (7 warnings at last baseline) and is the only necessary entry.
[
  ~r/Function ExUnit\./
]
