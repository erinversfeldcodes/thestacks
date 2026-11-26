# `:needs_dbt_warehouse` is excluded alongside `:deployed_only`, and the two are
# different preconditions that were conflated.
#
# `:deployed_only` means "needs a real deployed stack", selected by
# `scripts/test-deployed.sh` via `--only deployed_only`.
#
# `:needs_dbt_warehouse` means "needs ONE database holding both the test's own
# fixtures and a dbt-built warehouse". The warehouse tests carried
# `:deployed_only`, which cannot be satisfied: a deployed stack has the
# warehouse but not the fixtures, so they failed on every deployed run and the
# failure message blamed the absence of a deployed dbt run. That run has since
# happened and they stayed red, which is how the conflation surfaced.
ExUnit.configure(exclude: [:deployed_only, :needs_dbt_warehouse])
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Core.Repo, :manual)
