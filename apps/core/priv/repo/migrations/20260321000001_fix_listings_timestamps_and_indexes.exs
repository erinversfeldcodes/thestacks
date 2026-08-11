defmodule Core.Repo.Migrations.FixListingsTimestampsAndIndexes do
  @moduledoc """
    Adds indexes for marketplace listings:

    1. Partial composite index for expiry job (status='active' + expires_at)
    2. Partial unique index preventing duplicate draft/active listings per book+seller
  """

  use Ecto.Migration

  def change do
    create index(:listings, [:status, :expires_at],
             prefix: "op",
             where: "status = 'active'",
             name: "listings_active_expires_at_idx"
           )

    create unique_index(:listings, [:book_id, :seller_id],
             prefix: "op",
             where: "status IN ('draft', 'active')",
             name: "listings_active_book_seller_idx"
           )
  end
end
