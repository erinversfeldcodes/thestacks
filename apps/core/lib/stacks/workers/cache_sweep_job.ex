defmodule Stacks.Workers.CacheSweepJob do
  @moduledoc """
  Daily Oban cron worker that deletes expired rows from the persistent
  cache tables `op.isbn_resolver_cache` and `op.title_search_cache`.

  Without this, both tables grow unbounded — every ISBN/title ever
  looked up stays as a tombstone past its `expires_at`. Reads still
  filter on `expires_at > now()` so stale rows can't be served, but DB
  size matters for backup cost and query planner stats.

  Scheduled daily at 03:30 UTC (between ImageRetentionJob at 02:00 and
  RSSLivenessJob at 03:00). Uses an indexed range delete
  (`title_search_cache_expires_at_index` /
  `isbn_resolver_cache_expires_at_index`) so it remains cheap even as
  the tables grow — Postgres walks the index from the low end up to
  `now()` and drops the corresponding heap rows.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Books.IsbnResolverCacheEntry
  alias Stacks.Books.TitleSearchCacheEntry

  @impl true
  def perform(_job) do
    now = DateTime.utc_now()

    {isbn_deleted, _} =
      Repo.delete_all(from(e in IsbnResolverCacheEntry, where: e.expires_at <= ^now))

    {title_deleted, _} =
      Repo.delete_all(from(e in TitleSearchCacheEntry, where: e.expires_at <= ^now))

    Logger.info(
      "CacheSweepJob: deleted #{isbn_deleted} expired ISBN cache rows, " <>
        "#{title_deleted} expired title-search cache rows"
    )

    :ok
  end
end
