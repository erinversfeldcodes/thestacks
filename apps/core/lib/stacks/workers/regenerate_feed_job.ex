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

  # NOTE: deliberately NOT `unique:`. Placing N books enqueues N identical
  # regenerations, which is wasteful but harmless — the job recomputes the whole
  # feed and upserts one row per bookshelf, so the end state is correct either way.
  #
  # Deduping is tempting and is a trap worth writing down. Oban warns that unique
  # `states` omitting `:executing` "may break uniqueness", and the obvious fix —
  # adding `:executing` — introduces a LOST UPDATE here: a regeneration that is
  # already running may have read the placements before the newest one committed,
  # so collapsing the newest event into it drops that book from the feed until
  # something else triggers a regeneration. Any dedup must therefore exclude
  # `:executing` (and accept the warning), or debounce rather than deduplicate.
  # Not worth it for a batch path; revisit only with that analysis in hand.
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

        {:error, "feed cache write failed"}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.warning("RegenerateFeedJob: unexpected args shape: #{inspect(args)}")
    {:cancel, "invalid args"}
  end
end
