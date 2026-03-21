defmodule Stacks.Blog.Handlers.BlogAssociationHandler do
  @moduledoc """
  Event handler that triggers LLM-based book association when a blog post
  is published.

  Listens for `blog.post_published` and enqueues a
  `PostBookAssociationWorker` for the post.
  """

  @behaviour Stacks.Events.Handler

  require Logger

  alias Stacks.Workers.PostBookAssociationWorker

  @impl true
  def handle_event(%{event_type: "blog.post_published", aggregate_id: post_id}) do
    Logger.info("BlogAssociationHandler: enqueuing association worker for post #{post_id}")

    case %{post_id: post_id}
         |> PostBookAssociationWorker.new()
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "BlogAssociationHandler: failed to enqueue worker for post #{post_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @impl true
  def handle_event(_event), do: :ok
end
