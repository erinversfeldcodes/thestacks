defmodule Stacks.Workers.WritingAssistantDataPurgeWorkerTest do
  @moduledoc """
      — consent-revocation purge for the writing assistant.

      Proves the worker deletes the user's personal AI data sets (corpus
      annotations, imported works, sessions + cascaded turn_feedback/retrieval_log,
      embeddings, content-access), PRESERVES the shared book_content_chunks corpus
      and the user row, is idempotent (safe to perform twice), and only touches the
      target user's data.
  """
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Accounts.User
  alias Stacks.Workers.WritingAssistantDataPurgeWorker

  alias Stacks.WritingAssistant.{
    BookContentChunk,
    CorpusAnnotation,
    Embedding,
    ImportedWork,
    RetrievalLog,
    Session,
    TurnFeedback,
    UserBookContentAccess
  }

  @vec List.duplicate(1.0, 1024)

  defp seed_graph(user, book) do
    session = Repo.insert!(%Session{user_id: user.id, status: "active"})

    work =
      Repo.insert!(%ImportedWork{
        user_id: user.id,
        title: "Manuscript",
        source_format: "txt",
        imported_at: DateTime.utc_now()
      })

    %{
      session: session,
      work: work,
      annotation:
        Repo.insert!(%CorpusAnnotation{
          user_id: user.id,
          work_id: work.id,
          tags: ["exemplar"],
          note: "a private note"
        }),
      embedding:
        Repo.insert!(%Embedding{
          user_id: user.id,
          source_type: "shelf",
          title: "My Shelf",
          embedding: @vec
        }),
      feedback: Repo.insert!(%TurnFeedback{session_id: session.id, turn_index: 0, rating: "up"}),
      retrieval: Repo.insert!(%RetrievalLog{session_id: session.id, query: "cottage core"}),
      access:
        Repo.insert!(%UserBookContentAccess{
          user_id: user.id,
          book_id: book.id,
          access_type: "granted"
        }),
      chunk:
        Repo.insert!(%BookContentChunk{
          book_id: book.id,
          chunk_index: 0,
          content: "Shared corpus text — not personal.",
          embedding: Pgvector.new(@vec)
        })
    }
  end

  test "purges the personal AI data sets, preserves the shared corpus + user row" do
    user = insert(:user)
    book = insert(:book)
    g = seed_graph(user, book)

    assert :ok = perform_job(WritingAssistantDataPurgeWorker, %{"user_id" => user.id})

    refute Repo.get(CorpusAnnotation, g.annotation.id)
    refute Repo.get(ImportedWork, g.work.id)
    refute Repo.get(Session, g.session.id)
    refute Repo.get(TurnFeedback, g.feedback.id)
    refute Repo.get(RetrievalLog, g.retrieval.id)
    refute Repo.get(Embedding, g.embedding.id)
    refute Repo.get(UserBookContentAccess, g.access.id)

    assert Repo.get(BookContentChunk, g.chunk.id)
    assert Repo.get(User, user.id)
  end

  test "is idempotent — performing twice is safe and still returns :ok" do
    user = insert(:user)
    book = insert(:book)
    g = seed_graph(user, book)

    assert :ok = perform_job(WritingAssistantDataPurgeWorker, %{"user_id" => user.id})
    assert :ok = perform_job(WritingAssistantDataPurgeWorker, %{"user_id" => user.id})

    refute Repo.get(CorpusAnnotation, g.annotation.id)
    refute Repo.get(ImportedWork, g.work.id)
    refute Repo.get(Session, g.session.id)
    refute Repo.get(Embedding, g.embedding.id)
    refute Repo.get(UserBookContentAccess, g.access.id)
    assert Repo.get(BookContentChunk, g.chunk.id)
  end

  test "only purges the target user's data — another user's rows are untouched" do
    victim = insert(:user)
    bystander = insert(:user)
    book = insert(:book)

    _v = seed_graph(victim, book)
    b = seed_graph(bystander, book)

    assert :ok = perform_job(WritingAssistantDataPurgeWorker, %{"user_id" => victim.id})

    assert Repo.get(CorpusAnnotation, b.annotation.id)
    assert Repo.get(ImportedWork, b.work.id)
    assert Repo.get(Session, b.session.id)
    assert Repo.get(TurnFeedback, b.feedback.id)
    assert Repo.get(RetrievalLog, b.retrieval.id)
    assert Repo.get(Embedding, b.embedding.id)
    assert Repo.get(UserBookContentAccess, b.access.id)
  end
end
