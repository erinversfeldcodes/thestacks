defmodule Stacks.Workers.WritingAssistantEmbeddingWorker do
  @moduledoc """
      Produces and stores the retrieval embeddings for one source — a blog post
      or a bookshelf — on the vision CPU front door. The work itself is
      `Stacks.WritingAssistant.Embedder`; this is the Oban wrapper and the
      backfill's unit of work. Idempotent: a re-run replaces the source's rows.
  """

  use Stacks.Worker, scope: :user, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.WritingAssistant.Embedder

  @impl true
  def perform(%Oban.Job{
        args: %{"source_type" => source_type, "source_id" => id, "user_id" => uid}
      }) do
    case Embedder.embed_source(source_type, id, uid) do
      {:ok, written} ->
        Logger.info(
          "WritingAssistantEmbeddingWorker: embedded #{source_type} #{id} for user " <>
            "#{uid} — #{written} chunk(s)"
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "WritingAssistantEmbeddingWorker: failed to embed #{source_type} #{id} for user " <>
            "#{uid}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
