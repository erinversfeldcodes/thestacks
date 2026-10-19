defmodule Core.Repo.Migrations.LetTheDiscoveryFeedPageOnAnIndex do
  @moduledoc """
      Adds the keyset index the cross-author blog feed pages on:
      `op.blog_posts (published_at DESC, id DESC)` over published public and
      platform posts only.

      ## Why now

      The feed used to read the newest 50 rows and stop, so one sort of the
      matching rows served the only page anybody could ask for. It now pages with
      a keyset on `(published_at, id)`, and a reader walking back through the
      corpus asks that question repeatedly — without an index each page sorts the
      whole matching set again, and the deeper the reader goes the more of it is
      thrown away.

      The only existing index touching `published_at` is
      `(user_id, desc: published_at)` filtered to `visibility = 'public' AND
      syndicated`, which serves one author's syndication feed. It cannot drive
      this query twice over: a composite index is only usable from its leading
      column and there is no `user_id` predicate here, and its `syndicated`
      condition excludes most of the corpus the discovery feed is for.

      ## Shape

      Partial, on exactly the feed's predicate, so the index holds only rows the
      feed can return — drafts and group posts are the majority of a working
      author's table and have no business in it.

      `DESC, DESC` matches the order the feed asks for. Postgres can read a btree
      backwards, so an ascending index would also serve it; stating the direction
      keeps the index legible next to the query it exists for.

      ## Why CONCURRENTLY

      `op.blog_posts` is written on the request path — publishing a post is a
      user action — so a plain `CREATE INDEX` would hold a lock against writes for
      the duration. Concurrent creation needs its own transaction, hence
      `@disable_ddl_transaction`, and `statement_timeout = 0` because a timeout
      firing mid-build leaves an INVALID index behind, which is worse than never
      having started.

      ⚠️ `SET`, not `SET LOCAL`: with no transaction there is nothing for a LOCAL
      setting to scope to, so it would silently apply to nothing.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = 0")

    create_if_not_exists index(:blog_posts, [desc: :published_at, desc: :id],
                           prefix: "op",
                           name: :blog_posts_discovery_feed_index,
                           where:
                             "published_at IS NOT NULL AND visibility IN ('public', 'platform')",
                           concurrently: true
                         )
  end

  def down do
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = 0")

    drop_if_exists index(:blog_posts, [desc: :published_at, desc: :id],
                     prefix: "op",
                     name: :blog_posts_discovery_feed_index,
                     concurrently: true
                   )
  end
end
