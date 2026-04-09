ExUnit.configure(exclude: [:deployed_only, :sla])
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Core.Repo, :manual)
