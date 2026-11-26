defmodule Core.Repo.Migrations.RetainTransactionsWhenTheirListingIsErased do
  @moduledoc """
      A transaction is a financial record kept past the erasure of its parties —
      buyer_id and seller_id are already ON DELETE SET NULL. But listing_id was
      NOT NULL and ON DELETE CASCADE, and a seller's erasure cascade-deletes
      their listings, so the transaction was deleted with the listing, silently
      defeating the retention the two SET NULLs were there to provide.

      Make listing_id nullable and SET NULL on delete: the listing (and its free
      text) is erased with the user, while the pseudonymised transaction row
      survives carrying its amount, currency, status and date with no party or
      listing reference left.

      The new FK is added `NOT VALID` here (a brief lock, no scan); the sibling
      migration VALIDATEs it out of a transaction so the scan never holds an
      ACCESS EXCLUSIVE lock on a populated database.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("""
    -- squawk-ignore ban-drop-not-null
    ALTER TABLE op.transactions ALTER COLUMN listing_id DROP NOT NULL
    """)

    execute("ALTER TABLE op.transactions DROP CONSTRAINT IF EXISTS transactions_listing_id_fkey")

    execute("""
    ALTER TABLE op.transactions
      ADD CONSTRAINT transactions_listing_id_fkey
      FOREIGN KEY (listing_id) REFERENCES op.listings(id) ON DELETE SET NULL
      NOT VALID
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("ALTER TABLE op.transactions DROP CONSTRAINT IF EXISTS transactions_listing_id_fkey")

    execute("""
    ALTER TABLE op.transactions
      ADD CONSTRAINT transactions_listing_id_fkey
      FOREIGN KEY (listing_id) REFERENCES op.listings(id) ON DELETE CASCADE
      NOT VALID
    """)

    # down intentionally does NOT re-assert NOT NULL: a row retained past its
    # listing's erasure legitimately holds a NULL listing_id, and re-adding the
    # constraint would fail against it.
  end
end
