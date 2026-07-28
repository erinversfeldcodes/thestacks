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

  # Ordered as the story lists them, which is roughly "most to least obviously a
  # reading spot" — the order a reader would scan a filter list in.
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
      # IF NOT EXISTS makes this idempotent, which matters because a failed run cannot
      # be rolled back (see `down/0`).
      execute("ALTER TYPE op.space_type ADD VALUE IF NOT EXISTS '#{type}'")
    end
  end

  def down do
    # Postgres cannot remove a value from an enum. Reversing this would mean recreating
    # the type, rewriting every dependent column, and deciding what to do with rows
    # already using a removed value — which is a data migration, not a rollback.
    #
    # Deliberately a no-op rather than raising: `up/0` is idempotent and purely
    # additive, so leaving the values in place is harmless, whereas raising here would
    # block an unrelated rollback of a later migration.
    :ok
  end
end
