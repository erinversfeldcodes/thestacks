defmodule Stacks.Workers.RegenerateFeedJob do
  @moduledoc """
  Oban worker that regenerates an Atom feed when a shelf placement changes and
  upserts the result into the `op.feed_cache` store.

  Triggered by `placement.created`, `placement.moved`, and `placement.removed`
  events via the event handler `Stacks.Feeds.Handlers.PlacementHandler`.

  On a platform-visible bookshelf it renders the Atom XML and upserts the cache
  row (`Stacks.Feeds.regenerate/2`); the run is idempotent. The job is a no-op
  for non-platform-visible shelves — it logs a debug message and returns `:ok`
  without writing a row.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Feeds

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id, "bookshelf_name" => bookshelf_name}}) do
    Logger.info(
      "RegenerateFeedJob: regenerating feed for user=#{user_id} bookshelf=#{bookshelf_name}"
    )

    case Feeds.regenerate(user_id, bookshelf_name) do
      {:ok, _xml, etag} ->
        Logger.info(
          "RegenerateFeedJob: feed regenerated + cached for user=#{user_id} bookshelf=#{bookshelf_name} etag=#{etag}"
        )

        :ok

      {:error, :not_public} ->
        Logger.debug(
          "RegenerateFeedJob: bookshelf #{bookshelf_name} for user=#{user_id} is not platform-visible, skipping"
        )

        :ok

      {:error, :not_found} ->
        Logger.warning(
          "RegenerateFeedJob: bookshelf #{bookshelf_name} for user=#{user_id} not found"
        )

        {:cancel, "bookshelf not found"}

      {:error, {:cache_write_failed, changeset}} ->
        Logger.error(
          "RegenerateFeedJob: feed_cache write failed for user=#{user_id} bookshelf=#{bookshelf_name}: #{inspect(changeset.errors)}"
        )

        # Filling the cache is the whole point of this job — surface the failure
        # so Oban retries (max_attempts: 3) rather than dropping the update.
        {:error, "feed cache write failed"}
    end
  end

  # Catch-all for unexpected args shape
  def perform(%Oban.Job{args: args}) do
    Logger.warning("RegenerateFeedJob: unexpected args shape: #{inspect(args)}")
    {:cancel, "invalid args"}
  end
end
