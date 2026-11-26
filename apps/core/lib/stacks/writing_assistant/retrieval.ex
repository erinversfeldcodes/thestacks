defmodule Stacks.WritingAssistant.Retrieval do
  @moduledoc """
      Exact in-app k-nearest-neighbour retrieval over the author's own
      writing-assistant corpus.

      The vectors are AES-GCM-encrypted at rest (`Stacks.EncryptedVector`), so
      there is no ANN index and no full-text arm to search: a query decrypts the
      user's candidate vectors in memory, scores each against the query vector by
      cosine similarity, and keeps the top k. Only those top-k rows then have
      their chunk text decrypted, for prompt assembly — the brute-force scoring
      pass selects the vector alone and never touches `chunk_text`.

      Three guarantees this seam owns:

        * USER SCOPE — every candidate is filtered to `user_id`; one user's query
          can never reach another user's corpus.
        * DO-NOT-RETRIEVE — a chunk whose own annotation, or whose imported
          work's annotation, carries `do_not_retrieve` is excluded in SQL, before
          its vector or its text is ever decrypted.
        * NO LEAK — decrypted chunk text is returned to the caller and nowhere
          else; this module logs nothing containing corpus text.

      `embedding_version` is an exact-match filter: vectors produced by different
      model versions are not comparable, so the caller passes the version it
      embedded the query at and only same-version vectors are scored.
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.WritingAssistant.{CorpusAnnotation, Embedding}

  @default_k 8

  @type result :: %{
          id: binary(),
          score: float(),
          chunk_text: String.t() | nil,
          title: String.t() | nil,
          source_type: String.t(),
          source_id: binary() | nil,
          chunk_index: integer() | nil,
          char_start: integer() | nil,
          char_end: integer() | nil
        }

  @doc """
  Return the top-k chunks of `user_id`'s corpus nearest `query_vector`.

  Options:

    * `:embedding_version` (required) — only vectors of this version are scored.
    * `:k` — how many results to return (default #{@default_k}).
    * `:source_type` — restrict to one source kind (the metadata exact-match pass).
  """
  @spec retrieve(binary(), [float()], keyword()) :: [result()]
  def retrieve(user_id, query_vector, opts \\ []) when is_list(query_vector) do
    version = Keyword.fetch!(opts, :embedding_version)
    k = Keyword.get(opts, :k, @default_k)
    source_type = Keyword.get(opts, :source_type)

    {redacted_chunk_ids, redacted_work_ids} = redacted(user_id)

    scored =
      Embedding
      |> where([e], e.user_id == ^user_id and e.embedding_version == ^version)
      |> restrict_source_type(source_type)
      |> exclude_redacted(redacted_chunk_ids, redacted_work_ids)
      |> select([e], %{id: e.id, embedding: e.embedding})
      |> Repo.all()
      |> Enum.map(fn %{id: id, embedding: vector} -> {id, cosine(query_vector, vector)} end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(k)

    hydrate(user_id, scored)
  end

  # The redacted sets: embedding_ids directly flagged, and work_ids whose every
  # imported chunk is flagged. `do_not_retrieve` and the FK columns are plaintext,
  # so the exclusion happens in SQL and a redacted vector is never decrypted.
  defp redacted(user_id) do
    rows =
      CorpusAnnotation
      |> where([a], a.user_id == ^user_id and a.do_not_retrieve == true)
      |> select([a], {a.embedding_id, a.work_id})
      |> Repo.all()

    chunk_ids = for {embedding_id, _} <- rows, not is_nil(embedding_id), do: embedding_id
    work_ids = for {_, work_id} <- rows, not is_nil(work_id), do: work_id
    {chunk_ids, work_ids}
  end

  defp restrict_source_type(query, nil), do: query

  defp restrict_source_type(query, source_type),
    do: where(query, [e], e.source_type == ^source_type)

  defp exclude_redacted(query, [], []), do: query

  defp exclude_redacted(query, chunk_ids, []),
    do: where(query, [e], e.id not in ^chunk_ids)

  defp exclude_redacted(query, [], work_ids),
    do: where(query, [e], not (e.source_type == "imported_work" and e.source_id in ^work_ids))

  defp exclude_redacted(query, chunk_ids, work_ids) do
    query
    |> where([e], e.id not in ^chunk_ids)
    |> where([e], not (e.source_type == "imported_work" and e.source_id in ^work_ids))
  end

  # Decrypt chunk text (and citation metadata) for the surviving top-k only.
  defp hydrate(_user_id, []), do: []

  defp hydrate(user_id, scored) do
    ids = Enum.map(scored, &elem(&1, 0))
    score_of = Map.new(scored)

    Embedding
    |> where([e], e.user_id == ^user_id and e.id in ^ids)
    |> select([e], %{
      id: e.id,
      chunk_text: e.chunk_text,
      title: e.title,
      source_type: e.source_type,
      source_id: e.source_id,
      chunk_index: e.chunk_index,
      char_start: e.char_start,
      char_end: e.char_end
    })
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :score, Map.fetch!(score_of, &1.id)))
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp cosine(a, b), do: cosine(a, b, 0.0, 0.0, 0.0)

  defp cosine([x | xs], [y | ys], dot, norm_a, norm_b),
    do: cosine(xs, ys, dot + x * y, norm_a + x * x, norm_b + y * y)

  defp cosine([], [], dot, norm_a, norm_b) do
    denom = :math.sqrt(norm_a) * :math.sqrt(norm_b)
    if denom == 0.0, do: 0.0, else: dot / denom
  end
end
