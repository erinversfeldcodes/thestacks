defmodule Stacks.WritingAssistant.GdprDataModelTest do
  @moduledoc """
      — GDPR data-model foundation. Proves the writing-assistant /
      embeddings tables exist with the correct ownership + FK-cascade behaviour,
      the §4b.2 at-rest encryption posture (the vector is ciphertext at rest),
      and the personal-vs-shared erasure invariant that depends on them.
  """
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.GDPR.Deletion

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

  describe "schema" do
    test "the personal tables + shared corpus table exist with expected columns" do
      assert MapSet.subset?(
               MapSet.new(~w(id user_id source_type source_id title shelf content_date
                    chunk_text chunk_index char_start char_end model embedding_version)),
               columns("embeddings")
             )

      assert MapSet.subset?(
               MapSet.new(~w(id user_id title source_format source_sha256 imported_at)),
               columns("imported_works")
             )

      assert MapSet.subset?(
               MapSet.new(
                 ~w(id user_id work_id embedding_id tags exemplar_quality do_not_retrieve note)
               ),
               columns("corpus_annotations")
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

    test "imported_works and corpus_annotations are PERSONAL: they carry a user_id" do
      assert MapSet.member?(columns("imported_works"), "user_id")
      assert MapSet.member?(columns("corpus_annotations"), "user_id")
    end
  end

  describe "vector storage — encrypted at rest for embeddings" do
    test "the vector extension is installed (book_content_chunks still uses it)" do
      %{rows: rows} = Repo.query!("SELECT 1 FROM pg_extension WHERE extname = 'vector'")
      assert rows != []
    end

    test "embeddings.embedding is bytea (Cloak-encrypted); book_content_chunks stays vector(1024)" do
      assert vector_format("embeddings") == "bytea"
      assert vector_format("book_content_chunks") == "vector(1024)"
    end

    test "the embedding round-trips through EncryptedVector but is CIPHERTEXT at rest" do
      user = insert(:user)

      emb =
        Repo.insert!(%Embedding{
          user_id: user.id,
          source_type: "book",
          embedding: @vec
        })

      # Decrypts on load — the app sees the vector (float32 round-trips 1.0 exactly).
      loaded = Repo.get!(Embedding, emb.id)
      assert loaded.embedding == @vec

      # At rest the raw bytea is ciphertext: it neither equals nor contains the
      # float32 serialisation a plaintext vector column would have held. This is
      # the leak §4b.2 exists to prevent.
      plaintext = for component <- @vec, into: <<>>, do: <<component::float-32-little>>

      %{rows: [[raw]]} =
        Repo.query!("SELECT embedding FROM op.embeddings WHERE id = $1::uuid", [emb.id])

      assert is_binary(raw)
      refute raw == plaintext
      assert :binary.match(raw, plaintext) == :nomatch
    end
  end

  describe "erasure — FK cascade" do
    test "deleting the user row cascades to every personal table" do
      user = insert(:user)
      book = insert(:book)
      g = seed_graph(user, book)

      Repo.delete!(user)

      refute Repo.get(Embedding, g.embedding.id)
      refute Repo.get(ImportedWork, g.work.id)
      refute Repo.get(CorpusAnnotation, g.annotation.id)
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
    test "delete_user_data/1 erases every personal table and preserves the corpus" do
      user = insert(:user)
      book = insert(:book)
      g = seed_graph(user, book)

      assert {:ok, _} = Deletion.delete_user_data(user.id)

      refute Repo.get(Embedding, g.embedding.id)
      refute Repo.get(ImportedWork, g.work.id)
      refute Repo.get(CorpusAnnotation, g.annotation.id)
      refute Repo.get(Session, g.session.id)
      refute Repo.get(TurnFeedback, g.feedback.id)
      refute Repo.get(RetrievalLog, g.retrieval.id)
      refute Repo.get(UserBookContentAccess, g.access.id)

      assert Repo.get(BookContentChunk, g.chunk.id)
    end
  end
end
