defmodule Stacks.Workers.WritingAssistantDataPurgeWorker do
  @moduledoc """
      Purges a user's AI writing-assistant data on consent revocation —
      NOT account erasure; the user row stays. Deletes only what the grant
      collected: `op.blog_assistant_sessions` (cascades to `turn_feedback` +
      `retrieval_log`), `op.embeddings`, `op.user_book_content_access`.
      PRESERVES `op.book_content_chunks` — the shared, non-personal corpus.
      Idempotent (`delete_all` over `user_id`); audit-logged on completion.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Core.Repo
  alias Stacks.WritingAssistant.{Embedding, Session, UserBookContentAccess}

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    Logger.info("WritingAssistantDataPurgeWorker: purging AI data for user #{user_id}")

    {sessions, _} = Repo.delete_all(from s in Session, where: s.user_id == ^user_id)
    {embeddings, _} = Repo.delete_all(from e in Embedding, where: e.user_id == ^user_id)

    {access, _} =
      Repo.delete_all(from a in UserBookContentAccess, where: a.user_id == ^user_id)

    Logger.info(
      "WritingAssistantDataPurgeWorker: purged user #{user_id} — " <>
        "sessions=#{sessions} embeddings=#{embeddings} content_access=#{access}"
    )

    :ok
  end
end
