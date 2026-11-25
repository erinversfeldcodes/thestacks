defmodule Stacks.Workers.WritingAssistantEmbeddingWorkerTest do
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory
  import Ecto.Query

  alias Core.Repo
  alias Stacks.Workers.WritingAssistantEmbeddingWorker
  alias Stacks.WritingAssistant.{Embedder, Embedding}

  defp for_source(source_id), do: from(e in Embedding, where: e.source_id == ^source_id)

  describe "producing embeddings" do
    test "a blog post becomes encrypted, model-stamped embedding rows" do
      user = insert(:user)
      post = insert(:post, user: user, title: "On Attention", body: "A paragraph about reading.")

      assert :ok =
               perform_job(WritingAssistantEmbeddingWorker, %{
                 "source_type" => "blog_post",
                 "source_id" => post.id,
                 "user_id" => user.id
               })

      # Zero-row sweep: the producer actually ran and wrote rows (not built-but-not-wired).
      rows = Repo.all(for_source(post.id))
      assert rows != []

      row = hd(rows)
      assert row.source_type == "blog_post"
      assert row.model == "bge-m3"
      assert row.embedding_version == 1
      assert row.chunk_index == 0
      assert row.chunk_text =~ "On Attention"

      # Decrypts through EncryptedVector back to the model's vector; 0.5 is exact
      # in float32, so the round-trip is lossless and this can assert exactly.
      assert length(row.embedding) == 1024
      assert row.embedding == List.duplicate(0.5, 1024)
    end

    test "a bookshelf name is embedded under source_type shelf" do
      user = insert(:user)
      shelf = insert(:bookshelf, user: user, name: "antilibrary")

      assert :ok =
               perform_job(WritingAssistantEmbeddingWorker, %{
                 "source_type" => "shelf",
                 "source_id" => shelf.id,
                 "user_id" => user.id
               })

      assert [row] = Repo.all(for_source(shelf.id))
      assert row.source_type == "shelf"
      assert row.shelf == "antilibrary"
      assert row.chunk_text == "antilibrary"
    end

    test "re-embedding a source replaces its rows rather than duplicating them" do
      user = insert(:user)
      post = insert(:post, user: user, title: "T", body: "B")
      args = %{"source_type" => "blog_post", "source_id" => post.id, "user_id" => user.id}

      assert :ok = perform_job(WritingAssistantEmbeddingWorker, args)
      count1 = Repo.aggregate(for_source(post.id), :count)
      assert :ok = perform_job(WritingAssistantEmbeddingWorker, args)
      count2 = Repo.aggregate(for_source(post.id), :count)

      assert count1 > 0
      assert count2 == count1
    end

    test "a missing source returns an error, writes nothing" do
      user = insert(:user)
      missing = Ecto.UUID.generate()

      assert {:error, :source_not_found} =
               Embedder.embed_source("blog_post", missing, user.id)

      assert Repo.aggregate(for_source(missing), :count) == 0
    end
  end

  describe "backfill" do
    test "enqueues one job per post and bookshelf" do
      user = insert(:user)
      insert(:post, user: user)
      insert(:post, user: user)
      insert(:bookshelf, user: user, name: "library")

      assert Embedder.backfill_all() == 3

      assert_enqueued(
        worker: WritingAssistantEmbeddingWorker,
        args: %{"source_type" => "blog_post"}
      )

      assert_enqueued(worker: WritingAssistantEmbeddingWorker, args: %{"source_type" => "shelf"})
    end
  end
end
