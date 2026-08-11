defmodule Stacks.Workers.PostBookAssociationWorker do
  @moduledoc """
      Oban worker that uses an LLM to discover which books from the catalogue
      are discussed in a newly published blog post.

      Triggered by `blog.post_published` via `BlogAssociationHandler`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Blog
  alias Stacks.Books.Book
  alias Stacks.Events

  @impl true
  def perform(%Oban.Job{args: %{"post_id" => post_id}}) do
    case Blog.get_post(post_id) do
      nil ->
        Logger.warning("PostBookAssociationWorker: post #{post_id} not found")
        :ok

      post ->
        run_association(post)
    end
  end

  @max_books 200
  @max_post_length 4000

  defp run_association(post) do
    books =
      Repo.all(
        from(b in Book, order_by: [desc: b.created_at], limit: @max_books, preload: [:author])
      )

    if books == [] do
      Logger.info("PostBookAssociationWorker: no books in catalogue, skipping")
      :ok
    else
      prompt = build_prompt(post.body, books)

      case together_client().complete(prompt, max_tokens: 1024, temperature: 0.2) do
        {:ok, response} ->
          handle_response(post, response)

        {:error, reason} ->
          Logger.warning(
            "PostBookAssociationWorker: LLM call failed for post #{post.id}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  defp build_prompt(post_body, books) when is_binary(post_body) do
    post_body = String.slice(post_body, 0, @max_post_length)

    book_list =
      Enum.map_join(books, "\n", fn book ->
        author_name = if book.author, do: book.author.name, else: "Unknown"
        "- #{book.id}: \"#{book.title}\" by #{author_name}"
      end)

    """
    You are analyzing a blog post to find which books from a catalogue are discussed.

    Post content:
    #{post_body}

    Books in catalogue:
    #{book_list}

    Return a JSON array of objects with keys: book_id, confidence (0.0-1.0), reasoning.
    Only include books that are clearly discussed or referenced in the post. Return [] if none.
    """
  end

  defp handle_response(post, response) do
    case Jason.decode(response) do
      {:ok, associations} when is_list(associations) ->
        persist_associations(post, associations)

      {:ok, _other} ->
        Logger.warning("PostBookAssociationWorker: unexpected JSON shape for post #{post.id}")

        :ok

      {:error, _reason} ->
        Logger.warning(
          "PostBookAssociationWorker: failed to parse LLM response for post #{post.id}"
        )

        :ok
    end
  end

  defp persist_associations(post, associations) do
    book_ids =
      associations
      |> Enum.filter(&Map.get(&1, "book_id"))
      |> Enum.reduce([], fn assoc, acc -> associate_single(post, assoc, acc) end)

    Events.emit_safe(%{
      event_type: "blog.associations_suggested",
      aggregate_type: "post",
      aggregate_id: post.id,
      payload: %{book_ids: book_ids, count: length(book_ids)}
    })

    :ok
  end

  defp associate_single(post, assoc, acc) do
    book_id = Map.get(assoc, "book_id")
    confidence = Map.get(assoc, "confidence", 0.5)
    reasoning = Map.get(assoc, "reasoning")
    attrs = %{source: "llm", confidence: confidence, reasoning: reasoning, visible: true}

    case Blog.associate_book(post, book_id, attrs) do
      {:ok, _} ->
        [book_id | acc]

      {:error, reason} ->
        Logger.warning(
          "PostBookAssociationWorker: failed to associate book #{book_id}: #{inspect(reason)}"
        )

        acc
    end
  end

  defp together_client do
    Application.get_env(:core, :together_client, Stacks.AI.TogetherClient)
  end
end
