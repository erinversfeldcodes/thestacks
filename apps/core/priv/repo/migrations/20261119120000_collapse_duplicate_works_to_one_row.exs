defmodule Core.Repo.Migrations.CollapseDuplicateWorksToOneRow do
  @moduledoc """
  One-time cleanup: the catalogue had accumulated the same work as more than one
  `op.books` row (the same title and author uploaded as separate editions each
  minting a fresh work). `Stacks.Books.dedup_works/0` merges every such duplicate
  into its oldest sibling — re-parenting editions, placements, listings, images
  and the rest onto the survivor, consolidating any unique-key collisions, and
  deleting the duplicate row. No user data is lost; references are re-pointed.
  """
  use Ecto.Migration

  # Each merge runs in its own transaction inside `dedup_works/0`; wrapping the
  # whole pass in one DDL transaction would hold locks across every merge and, on
  # a large catalogue, time out. A partial run is safe to resume — the pass is
  # idempotent, re-finding only the duplicates that remain.
  @disable_ddl_transaction true

  def up do
    Stacks.Books.dedup_works()
  end

  def down do
    # A merge cannot be reversed: the duplicate rows are gone and their editions
    # and placements now belong to the survivor. There is nothing to restore.
    :ok
  end
end
