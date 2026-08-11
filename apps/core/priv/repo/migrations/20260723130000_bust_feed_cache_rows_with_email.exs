defmodule Core.Repo.Migrations.BustFeedCacheRowsWithEmail do
  @moduledoc """
  Data-only (283): deletes `op.feed_cache` rows whose `atom_xml` contains
  an email-shaped string — pre-fix feeds rendered the owner's email into
  public Atom XML when `display_name` was nil. Safe and self-healing: a
  cache miss serves a fresh (email-free) render and refills; without a
  TTL, a stale hit would leak indefinitely.
  """
  use Ecto.Migration

  @disable_ddl_transaction false

  def up do
    execute("""
    DELETE FROM op.feed_cache
    WHERE atom_xml ~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}'
    """)
  end

  def down do
    :ok
  end
end
