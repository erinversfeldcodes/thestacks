defmodule Stacks.Enrichment.Handlers.AuthorDiscoveryHandler do
  @moduledoc """
  Event handler that triggers author source discovery when a new book is created.

  On `book.created`: extracts the author_id from the book, checks if the author
  has sources already, and if not enqueues a `DiscoverAuthorSourcesJob`.
  """

  @behaviour Stacks.Events.Handler

  require Logger

  alias Stacks.Books.Book
  alias Stacks.Enrichment.Authors
  alias Stacks.Workers.DiscoverAuthorSourcesJob

  @impl true
  def handle_event(%{event_type: "book.created", aggregate_id: book_id})
      when is_binary(book_id) do
    case get_author_id_for_book(book_id) do
      nil ->
        Logger.debug("AuthorDiscoveryHandler: no author for book #{book_id}")
        :ok

      author_id ->
        maybe_enqueue_discovery(author_id)
    end
  end

  def handle_event(_event), do: :ok

  defp maybe_enqueue_discovery(author_id) do
    case Authors.get_author(author_id) do
      nil ->
        :ok

      author ->
        if is_nil(author.website_url) or is_nil(author.rss_feed_url) do
          enqueue_discovery_job(author_id)
        end

        :ok
    end
  end

  defp enqueue_discovery_job(author_id) do
    Logger.info("AuthorDiscoveryHandler: enqueuing discovery for author #{author_id}")

    case %{author_id: author_id}
         |> DiscoverAuthorSourcesJob.new()
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "AuthorDiscoveryHandler: failed to enqueue discovery for author #{author_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp get_author_id_for_book(book_id) do
    import Ecto.Query

    Core.Repo.one(from(b in Book, where: b.id == ^book_id, select: b.author_id))
  end
end
