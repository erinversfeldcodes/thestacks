defmodule Core.Repo.Migrations.AddDiscoveredSourcesUrlUniqueIndex do
  use Ecto.Migration

  def change do
    create unique_index(:discovered_sources, [:url], prefix: "op")
  end
end
