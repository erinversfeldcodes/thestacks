defmodule Stacks.WritingAssistant.GdprDataModelTest do
  @moduledoc """
  Issue #183 — GDPR data-model foundation. Proves the writing-assistant /
  embeddings tables exist with the correct ownership + FK-cascade behaviour and
  the personal-vs-shared erasure invariant that #185 depends on.
  """
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.GDPR.Deletion

  alias Stacks.WritingAssistant.{
    BookContentChunk,
    Embedding,
    RetrievalLog,
    Session,
    TurnFeedback,
    UserBookContentAccess
  }

  @vec List.duplicate(1.0, 1024)

  defp columns(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = 'op' AND table_name = $1",
        [table]
      )

    rows |> List.flatten() |> MapSet.new()
  end

  defp vector_format(table) do
    %{rows: [[fmt]]} =
      Repo.query!(
        "SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a " <>
          "JOIN pg_class c ON a.attrelid = c.oid " <>
          "JOIN pg_namespace n ON c.relnamespace = n.oid " <>
          "WHERE n.nspname = 'op' AND c.relname = $1 AND a.attname = 'embedding'",
        [table]
      )

    fmt
  end

  defp seed_graph(user, book) do
    session = Repo.insert!(%Session{user_id: user.id, status: "active"})

    %{
      session: session,
      embedding:
        Repo.insert!(%Embedding{
          user_id: user.id,
          source_type: "shelf",
          title: "My Shelf",
          embedding: Pgvector.new(@vec)
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

  describe "schema" do
    test "the five personal tables + shared corpus table exist with expected columns" do
      assert MapSet.subset?(
               MapSet.new(~w(id user_id source_type source_id title shelf content_date)),
               columns("embeddings")
             )

      assert MapSet.subset?(
               MapSet.new(~w(id user_id status topic model started_at)),
               columns("blog_assistant_sessions")
             )

      assert MapSet.subset?(
               MapSet.new(~w(id session_id turn_index rating comment)),
               columns("turn_feedback")
             )

      assert MapSet.subset?(
               MapSet.new(~w(id session_id query retrieved_ids scores turn_index)),
               columns("retrieval_log")
             )

      assert MapSet.subset?(
               MapSet.new(~w(id user_id book_id access_type granted_at)),
               columns("user_book_content_access")
             )

      assert MapSet.subset?(
               MapSet.new(~w(id book_id chunk_index content token_count)),
               columns("book_content_chunks")
             )
    end

    test "book_content_chunks is SHARED, NON-personal: it has NO user_id column" do
      refute MapSet.member?(columns("book_content_chunks"), "user_id")
    end
  end

  describe "pgvector" do
    test "the vector extension is installed" do
      %{rows: rows} = Repo.query!("SELECT 1 FROM pg_extension WHERE extname = 'vector'")
      assert rows != []
    end

    test "embedding columns are vector(1024) on both embeddings and book_content_chunks" do
      assert vector_format("embeddings") == "vector(1024)"
      assert vector_format("book_content_chunks") == "vector(1024)"
    end

    test "a 1024-dim vector round-trips through the Pgvector.Ecto.Vector field" do
      user = insert(:user)

      emb =
        Repo.insert!(%Embedding{
          user_id: user.id,
          source_type: "book",
          embedding: Pgvector.new(@vec)
        })

      loaded = Repo.get!(Embedding, emb.id)
      assert Pgvector.to_list(loaded.embedding) == @vec
    end
  end

  describe "erasure — FK cascade (load-bearing for #185)" do
    test "deleting the user row cascades to all five personal tables" do
      user = insert(:user)
      book = insert(:book)
      g = seed_graph(user, book)

      Repo.delete!(user)

      refute Repo.get(Embedding, g.embedding.id)
      refute Repo.get(Session, g.session.id)
      refute Repo.get(TurnFeedback, g.feedback.id)
      refute Repo.get(RetrievalLog, g.retrieval.id)
      refute Repo.get(UserBookContentAccess, g.access.id)
    end

    test "deleting the user preserves the shared book_content_chunks row" do
      user = insert(:user)
      book = insert(:book)
      g = seed_graph(user, book)

      Repo.delete!(user)

      assert Repo.get(BookContentChunk, g.chunk.id)
    end
  end

  describe "erasure — real GDPR path (Stacks.GDPR.Deletion)" do
    test "delete_user_data/1 erases the five personal tables and preserves the corpus" do
      user = insert(:user)
      book = insert(:book)
      g = seed_graph(user, book)

      assert {:ok, _} = Deletion.delete_user_data(user.id)

      refute Repo.get(Embedding, g.embedding.id)
      refute Repo.get(Session, g.session.id)
      refute Repo.get(TurnFeedback, g.feedback.id)
      refute Repo.get(RetrievalLog, g.retrieval.id)
      refute Repo.get(UserBookContentAccess, g.access.id)

      assert Repo.get(BookContentChunk, g.chunk.id)
    end
  end
end
