defmodule Core.Repo.Migrations.ExtendSpaceTypeForThirdSpacesMap do
  @moduledoc """
  Adds the ten place categories US-3.1.1 §3 specifies to the `op.space_type` enum.

  The enum was `{reading_group, cafe, bookshop, festival, market}` — an **events and
  venues** taxonomy, written for the discovery stories (US-2.5.1/2.5.2) that populate
  third spaces from search. US-3.1.1 needs a **places you can sit and read** taxonomy:
  café, restaurant, bar/pub, park, garden, library, museum, square, beach, university
  campus, community centre. Only `cafe` appears in both.

  So the map's category filter was unbuildable as specified, and this was invisible
  until a test tried to insert `type: "garden"` and Postgres refused it. Worth recording
  as the reason: the story's category table and the database's enum were written by
  different stories months apart, and nothing compared them.

  **Additive only — the existing five values are kept.** They are not dead: the
  discovery pipeline writes `reading_group`, `festival` and `market`, and US-2.5.2 reads
  them. Removing an enum value would also require rewriting rows, and enum values, like
  proto field numbers, are cheapest treated as permanent.

  Each value maps to an OpenStreetMap tag (recorded in the story) so no bespoke data
  entry is required. `bar` and `pub` are separate values rather than one `bar_pub`
  because OSM tags them separately and collapsing them would lose information the
  producer already has.

  `ALTER TYPE ... ADD VALUE` cannot be followed by use of the new value inside the same
  transaction, so this runs outside one.
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
