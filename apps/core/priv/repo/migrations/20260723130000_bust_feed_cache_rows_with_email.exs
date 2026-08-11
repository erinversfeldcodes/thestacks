defmodule Core.Repo.Migrations.BustFeedCacheRowsWithEmail do
  @moduledoc """
  Data-only migration for #283. Deletes any `op.feed_cache` row whose stored
  `atom_xml` contains an email-shaped string — pre-fix feeds rendered the owner's
  email into a public Atom document's <title>/<author> when `display_name` was
  nil (see Stacks.Feeds.feed_display_name/1, which now falls back to the handle /
  a neutral label instead).

  Busting is safe and self-healing: #266 made a feed cache miss serve a fresh
  render (and refill the cache), so a deleted row is transparently regenerated —
  with the email-free XML — on the next read or the next RegenerateFeedJob run.
  There is no TTL on feed_cache, so a stale hit would otherwise serve the leaking
  XML indefinitely; deletion is the only way to guarantee the cached copy is
  refreshed. Data-only + idempotent: a no-op on a fresh DB (no rows) and on any
  DB already free of email-bearing feeds.
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
