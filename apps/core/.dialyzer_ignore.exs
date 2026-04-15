# Ignore ExUnit function warnings in test support modules.
# With MIX_ENV=test, elixirc_paths includes test/support/ — dialyzer checks
# the compiled beams but can't resolve ExUnit internal functions.
[
  ~r/Function ExUnit\./
]
