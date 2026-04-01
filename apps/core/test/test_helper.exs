ExUnit.configure(exclude: [:deployed_only, :security_gap])
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Core.Repo, :manual)
