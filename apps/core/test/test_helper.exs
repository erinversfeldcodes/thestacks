ExUnit.configure(exclude: [:deployed_only])
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Core.Repo, :manual)
