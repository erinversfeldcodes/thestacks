defmodule Core.Repo.Migrations.ExtendSpaceTypeForThirdSpacesMap do
  @moduledoc """
      Adds ten place categories to `op.space_type`. The enum was
      an events-and-venues taxonomy (reading_group, cafe, bookshop, festival,
      market — written for the discovery stories); needs
      places-you-can-sit-and-read (garden, park, library, …; only `cafe`
      overlaps), so the map's category filter was unbuildable until Postgres
      refused `type: "garden"` in a test. Enum additions are one-way —
      `ALTER TYPE … ADD VALUE` has no DROP — so `down` is a no-op.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @new_types ~w(
    restaurant
    bar
    pub
    park
    garden
    library
    museum
    square
    beach
    university
    community_centre
  )

  def up do
    for type <- @new_types do
      execute("ALTER TYPE op.space_type ADD VALUE IF NOT EXISTS '#{type}'")
    end
  end

  def down do
    :ok
  end
end
