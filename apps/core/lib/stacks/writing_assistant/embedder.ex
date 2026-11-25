defmodule Stacks.WritingAssistant.Embedder do
  @moduledoc """
      Produces writing-assistant retrieval vectors on the vision CPU front door
      and writes them to `op.embeddings`, Cloak-encrypted and model-stamped.

      One source (a blog post or a bookshelf) becomes one or more chunks; each
      chunk is embedded by `POST /embed` on the CPU front door (bge-m3, no GPU)
      and stored with its span provenance (`chunk_index` + char offsets) so a
      citation is honest, and with the model that ACTUALLY ran so a re-embed
      under a new model coexists rather than overwrites. Re-embedding a source
      replaces that source's own rows (delete-by-source, then insert), so the
      worker is idempotent.

      GDPR: `op.embeddings` is PERSONAL, user-scoped; erasure (account + consent)
      and export are wired at the substrate. This only populates it, under the
      owning user's scope.
  """

  import Ecto.Query
  require Logger

  alias Core.Repo
  alias Stacks.AI.Client, as: AIClient
  alias Stacks.Blog.Post
  alias Stacks.Scope
  alias Stacks.Shelving.Bookshelf
  alias Stacks.Workers.WritingAssistantEmbeddingWorker
  alias Stacks.WritingAssistant.Embedding

  @model "bge-m3"
  @embedding_version 1
  @chunk_chars 512
  @expected_dim 1024

  @doc """
      Embed one source for its owner and write the encrypted rows, replacing any
      the source had before. Returns `{:ok, rows_written}` or `{:error, reason}`.
  """
  @spec embed_source(String.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def embed_source(source_type, source_id, user_id) do
    Scope.with_user(user_id, fn ->
      with {:ok, source} <- load_source(source_type, source_id, user_id) do
        embed_and_write(source_type, source_id, user_id, source)
      end
    end)
  end

  @doc """
      Enqueue an embedding job for every blog post and bookshelf on the platform
      — the model-stamped backfill for existing content. Returns the number of
      jobs enqueued.
  """
  @spec backfill_all() :: non_neg_integer()
  def backfill_all do
    jobs =
      Enum.map(Repo.all(from(p in Post, select: {p.id, p.user_id})), &job("blog_post", &1)) ++
        Enum.map(Repo.all(from(b in Bookshelf, select: {b.id, b.user_id})), &job("shelf", &1))

    Oban.insert_all(jobs)
    length(jobs)
  end

  defp job(source_type, {source_id, user_id}) do
    WritingAssistantEmbeddingWorker.new(%{
      "source_type" => source_type,
      "source_id" => source_id,
      "user_id" => user_id
    })
  end

  defp load_source("blog_post", id, user_id) do
    case Repo.get_by(Post, id: id, user_id: user_id) do
      nil ->
        {:error, :source_not_found}

      post ->
        {:ok, %{title: post.title, shelf: nil, date: post.published_at, text: body_text(post)}}
    end
  end

  defp load_source("shelf", id, user_id) do
    case Repo.get_by(Bookshelf, id: id, user_id: user_id) do
      nil -> {:error, :source_not_found}
      shelf -> {:ok, %{title: nil, shelf: shelf.name, date: shelf.created_at, text: shelf.name}}
    end
  end

  defp load_source(other, _id, _user_id), do: {:error, {:unknown_source_type, other}}

  defp body_text(%Post{title: title, body: body}) do
    [title, body] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n\n")
  end

  defp embed_and_write(source_type, source_id, user_id, %{text: text} = source) do
    chunks = chunk(text)

    case AIClient.call_vision("embed", %{texts: Enum.map(chunks, &elem(&1, 0)), model: @model}) do
      {:ok, %{"vectors" => vectors, "model" => model, "dim" => dim}} ->
        cond do
          dim != @expected_dim ->
            {:error, {:unexpected_dim, dim}}

          length(vectors) != length(chunks) ->
            {:error, {:vector_count_mismatch, length(vectors), length(chunks)}}

          true ->
            write_rows(source_type, source_id, user_id, source, chunks, vectors, model)
        end

      {:ok, other} ->
        {:error, {:malformed_embed_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_rows(source_type, source_id, user_id, source, chunks, vectors, model) do
    result =
      Repo.transaction(fn ->
        Repo.delete_all(
          from(e in Embedding,
            where:
              e.user_id == ^user_id and e.source_type == ^source_type and
                e.source_id == ^source_id
          )
        )

        chunks
        |> Enum.zip(vectors)
        |> Enum.with_index()
        |> Enum.each(fn {{{chunk_text, cstart, cend}, %{"values" => values}}, index} ->
          Repo.insert!(%Embedding{
            user_id: user_id,
            source_type: source_type,
            source_id: source_id,
            title: source.title,
            shelf: source.shelf,
            content_date: source.date,
            embedding: values,
            chunk_text: chunk_text,
            chunk_index: index,
            char_start: cstart,
            char_end: cend,
            model: model,
            embedding_version: @embedding_version
          })
        end)
      end)

    case result do
      {:ok, _} -> {:ok, length(chunks)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Fixed-width character chunks carrying their own offsets, so a retrieved span
  # can be cited back into the source. A short source (a shelf name) is one chunk.
  defp chunk(""), do: []

  defp chunk(text) do
    len = String.length(text)

    0
    |> Stream.iterate(&(&1 + @chunk_chars))
    |> Stream.take_while(&(&1 < len))
    |> Enum.map(fn start ->
      piece = String.slice(text, start, @chunk_chars)
      {piece, start, start + String.length(piece)}
    end)
  end
end
