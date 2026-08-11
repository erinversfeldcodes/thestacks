defmodule Stacks.Workers.CacheSweepJob do
  @moduledoc """
    Daily cron (03:30 UTC) deleting expired rows from
    `cache.isbn_resolver_cache` and `cache.title_search_cache`. Reads
    already filter `expires_at > now`, so this is about DB size (backup
    cost, planner stats), not correctness. Indexed range delete on
    `expires_at`, so it stays cheap as the tables grow.
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
