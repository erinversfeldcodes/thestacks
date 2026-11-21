defmodule Core.Repo.Migrations.AddTheSanctionedReviewSourcesToTheEnum do
  use Ecto.Migration

  # ALTER TYPE … ADD VALUE cannot run inside a transaction. Both switches are set
  # together for an enum-value addition on Neon: without the migration lock
  # disabled, the three autocommitting ADD VALUEs would hold Ecto's global
  # migration advisory lock across statement boundaries. Each ADD VALUE is a
  # sub-second pg_enum catalog change (no table rewrite, no table lock), so the
  # window is tiny — but releasing the lock is the standard for this operation.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # The sanctioned review sources are Open Library,
  # Reddit (already present), partner-pushed, and author/publisher RSS. The enum
  # only carried the OLD vocabulary (goodreads/reddit/storygraph/other), so three
  # of the four sanctioned values could not be stored and the write gate in
  # `review_snapshot_changeset/2` admitted a value the column then rejected.
  # Additive and idempotent; goodreads/storygraph stay (numbers are forever) but
  # the write path refuses them.
  def up do
    execute("ALTER TYPE op.review_source ADD VALUE IF NOT EXISTS 'open_library'")
    execute("ALTER TYPE op.review_source ADD VALUE IF NOT EXISTS 'partner'")
    execute("ALTER TYPE op.review_source ADD VALUE IF NOT EXISTS 'author_rss'")
  end

  # Postgres cannot remove an enum value, so this is intentionally irreversible.
  def down, do: :ok
end
