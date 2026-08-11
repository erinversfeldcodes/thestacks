defmodule Core.Repo.Migrations.ValidateNewConstraints do
  @moduledoc """
    Validates the three 335 constraints added `NOT VALID` (two owner FKs +
    the ISBN CHECK). Its own migration because `VALIDATE CONSTRAINT` only
    takes the gentle SHARE UPDATE EXCLUSIVE lock when run in a DIFFERENT
    transaction from the ADD — same-transaction validation holds the ADD's
    ACCESS EXCLUSIVE lock across the whole scan, the outage `NOT VALID`
    exists to avoid.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute(
      "ALTER TABLE op.auth_token_families VALIDATE CONSTRAINT auth_token_families_user_id_fkey"
    )

    execute("ALTER TABLE op.guardian_tokens VALIDATE CONSTRAINT guardian_tokens_user_id_fkey")

    execute("ALTER TABLE op.book_editions VALIDATE CONSTRAINT book_editions_isbn_ean13_checksum")
  end

  def down, do: :ok
end
