defmodule Stacks.WritingAssistant.Corpus do
  @moduledoc """
      The author's OWN writing corpus: importing unpublished documents and
      annotating them.

      IMPORT: a document's bytes are base64'd straight to the CPU front door's
      `/extract-document`, the returned text is chunked + embedded via the shared
      `Stacks.WritingAssistant.Embedder`, and the original bytes are DISCARDED —
      never persisted. The only retention surface is the encrypted chunks in
      op.embeddings and the op.imported_works metadata row (whose title is
      Cloak-encrypted; `source_sha256` is a content digest, not the content).

      ANNOTATION: a first-class `op.corpus_annotations` row targets exactly one of
      a work or a chunk (DB XOR), carrying tags, an exemplar-quality score, a
      `do_not_retrieve` redaction flag (enforced at the retrieval seam), and
      an encrypted free-text note.

      Everything here is PERSONAL, under the `writing_assistant` consent: erased on
      account deletion (FK cascade) and on consent revocation (the purge worker),
      and included in export — all wired at the schema substrate.
  """

  require Logger

  alias Core.Repo
  alias Stacks.AI.Client, as: AIClient
  alias Stacks.Scope
  alias Stacks.WritingAssistant.{CorpusAnnotation, Embedder, ImportedWork}

  @supported_formats ~w(pdf epub docx md txt)

  @doc "The document formats the corpus can ingest."
  @spec supported_formats() :: [String.t()]
  def supported_formats, do: @supported_formats

  @doc """
      Import one document for a user: extract it on the CPU front door, chunk +
      embed + store the encrypted chunks, and record the work. `content` is the
      raw bytes; `format` is one of `supported_formats/0`. The bytes are not
      persisted. Returns `{:ok, %{work: ImportedWork.t(), chunks: non_neg_integer}}`.
  """
  @spec import_document(Ecto.UUID.t(), String.t(), binary(), String.t()) ::
          {:ok, %{work: ImportedWork.t(), chunks: non_neg_integer()}} | {:error, term()}
  def import_document(user_id, title, content, format) when format in @supported_formats do
    Scope.with_user(user_id, fn ->
      with {:ok, %{"text" => text, "char_count" => char_count}} <-
             AIClient.call_vision("extract_document", %{
               content: Base.encode64(content),
               format: format
             }),
           :ok <- ensure_extracted(char_count),
           {:ok, work} <- create_work(user_id, title, format, content),
           {:ok, chunks} <-
             Embedder.embed_and_write("imported_work", work.id, user_id, %{
               text: text,
               title: title,
               shelf: nil,
               date: work.imported_at
             }) do
        Logger.info(
          "WritingAssistant.Corpus: imported #{format} for user #{user_id} — " <>
            "#{char_count} chars, #{chunks} chunk(s)"
        )

        {:ok, %{work: work, chunks: chunks}}
      end
    end)
  end

  def import_document(_user_id, _title, _content, format),
    do: {:error, {:unsupported_format, format}}

  @doc "Annotate a whole imported work (tags, exemplar_quality, do_not_retrieve, note)."
  @spec annotate_work(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, CorpusAnnotation.t()} | {:error, term()}
  def annotate_work(user_id, work_id, attrs),
    do: annotate(user_id, [work_id: work_id, embedding_id: nil], attrs)

  @doc "Annotate a single chunk (an op.embeddings row)."
  @spec annotate_chunk(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, CorpusAnnotation.t()} | {:error, term()}
  def annotate_chunk(user_id, embedding_id, attrs),
    do: annotate(user_id, [work_id: nil, embedding_id: embedding_id], attrs)

  defp annotate(user_id, target, attrs) do
    Scope.with_user(user_id, fn ->
      annotation =
        Repo.insert!(%CorpusAnnotation{
          user_id: user_id,
          work_id: target[:work_id],
          embedding_id: target[:embedding_id],
          tags: Map.get(attrs, :tags, []),
          exemplar_quality: Map.get(attrs, :exemplar_quality),
          do_not_retrieve: Map.get(attrs, :do_not_retrieve, false),
          note: Map.get(attrs, :note)
        })

      {:ok, annotation}
    end)
  end

  defp ensure_extracted(char_count) when is_integer(char_count) and char_count > 0, do: :ok
  defp ensure_extracted(_), do: {:error, :no_text_extracted}

  defp create_work(user_id, title, format, content) do
    sha = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    {:ok,
     Repo.insert!(%ImportedWork{
       user_id: user_id,
       title: title,
       source_format: format,
       source_sha256: sha,
       imported_at: DateTime.utc_now()
     })}
  end
end
