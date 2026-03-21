defmodule Stacks.Workers.RegenerateFeedJob do
  @moduledoc """
  Oban worker that regenerates an Atom feed when a shelf placement changes.

  Triggered by `placement.created`, `placement.moved`, and `placement.removed`
  events via the event handler `Stacks.Feeds.Handlers.PlacementHandler`.

  The job is a no-op for non-platform-visible shelves — it logs a debug
  message and returns `:ok`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Feeds

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id, "bookshelf_name" => bookshelf_name}}) do
    Logger.info(
      "RegenerateFeedJob: regenerating feed for user=#{user_id} bookshelf=#{bookshelf_name}"
    )

    case Feeds.generate_atom(user_id, bookshelf_name) do
      {:ok, _xml, etag} ->
        Logger.info(
          "RegenerateFeedJob: feed regenerated for user=#{user_id} bookshelf=#{bookshelf_name} etag=#{etag}"
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
    end
  end

  # Catch-all for unexpected args shape
  def perform(%Oban.Job{args: args}) do
    Logger.warning("RegenerateFeedJob: unexpected args shape: #{inspect(args)}")
    {:cancel, "invalid args"}
  end
end
