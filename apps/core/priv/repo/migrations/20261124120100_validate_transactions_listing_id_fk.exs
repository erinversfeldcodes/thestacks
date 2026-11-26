defmodule Core.Repo.Migrations.ValidateTransactionsListingIdFk do
  @moduledoc """
      Validates the transactions.listing_id FK added `NOT VALID` by the sibling
      migration. Its own migration, out of a transaction, because `VALIDATE
      CONSTRAINT` scans the table under a SHARE UPDATE EXCLUSIVE lock — which
      allows reads and writes — only when it is not wrapped in the migration
      transaction; inside one it would hold the stronger lock for the scan.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = 0")
    execute("ALTER TABLE op.transactions VALIDATE CONSTRAINT transactions_listing_id_fkey")
  end

  def down, do: :ok
end
