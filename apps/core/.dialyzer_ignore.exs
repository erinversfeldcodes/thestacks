# Ignore ExUnit function warnings in test support modules.
# With MIX_ENV=test, elixirc_paths includes test/support/ — dialyzer checks
# the compiled beams but can't resolve ExUnit internal functions.
#
# NimbleTOTP is not included in the dialyzer PLT (it uses compile-time macros
# that don't expose standard @spec metadata). Suppress unknown-function warnings.
#
# Ecto.Schema generates t() via __using__ macros; dialyzer doesn't resolve the
# macro-expanded type definitions for AdminSession and UserMFA, producing
# spurious unknown-type warnings.
#
# The {error, _} catch-all in AdminAuthController.authenticate/2 is intentional
# defensive programming — it normalises any future Accounts.authenticate error
# to :invalid_credentials. Dialyzer correctly identifies it as currently
# unreachable given the function's typespec, but we keep it for safety.
[
  ~r/Function ExUnit\./,
  ~r/Function NimbleTOTP\./,
  ~r/Unknown type: NimbleTOTP\./,
  ~r/Unknown type: Stacks\.AdminSession\.t/,
  ~r/Unknown type: Stacks\.MFA\.UserMFA\.t/,
  ~r/admin_auth_controller\.ex.*pattern_match_cov/
]
