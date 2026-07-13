defmodule Stacks.Workers.WritingAssistantDataPurgeWorker do
  @moduledoc """
  Oban worker that purges a user's AI writing-assistant data after they revoke
  `writing_assistant` consent (Issue #184).

  This is a CONSENT-REVOCATION purge, NOT account erasure: the user row stays.
  It deletes only the personal data collected under the writing-assistant grant:

    * `op.blog_assistant_sessions` — user-scoped. Deleting a session CASCADES
      (`ON DELETE CASCADE`) to its `op.turn_feedback` and `op.retrieval_log`
      rows, so those two tables are cleared transitively.
    * `op.embeddings`             — user-scoped retrieval vectors.
    * `op.user_book_content_access` — user-scoped content-access grants.

  PRESERVED: `op.book_content_chunks` is the SHARED, non-personal corpus (no
  `user_id`); it is never touched.

  Idempotent: every step is a `delete_all` over a `user_id` filter, so a retry
  after a partial/complete run simply deletes zero further rows and still
  returns `:ok`. Safe to run twice.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Core.Repo
  alias Stacks.WritingAssistant.{Embedding, Session, UserBookContentAccess}

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    Logger.info("WritingAssistantDataPurgeWorker: purging AI data for user #{user_id}")

    # Sessions first: the delete cascades to turn_feedback + retrieval_log via
    # their session_id FK (ON DELETE CASCADE). No need to delete those directly.
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
