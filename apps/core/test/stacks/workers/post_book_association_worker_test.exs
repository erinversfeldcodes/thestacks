defmodule Stacks.Workers.PostBookAssociationWorkerTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  alias Stacks.AI.MockTogetherClient
  alias Stacks.Blog
  alias Stacks.Workers.PostBookAssociationWorker

  import Stacks.Factory

  describe "perform/1" do
    test "associates books when LLM returns valid JSON" do
      user = insert(:user)
      book = insert(:book, title: "Circe")
      post = insert(:post, user: user, body: "I loved reading Circe last month.")

      response =
        Jason.encode!([
          %{book_id: book.id, confidence: 0.95, reasoning: "Directly discussed"}
        ])

      MockTogetherClient.put_response({:ok, response})

      assert :ok == perform_job(PostBookAssociationWorker, %{post_id: post.id})

      associations = Blog.list_associations(post.id)
      assert length(associations) == 1

      assoc = hd(associations)
      assert assoc.book_id == book.id
      assert assoc.confidence == 0.95
      assert assoc.source == "llm"
      assert assoc.reasoning == "Directly discussed"
    end

    test "returns :ok when LLM returns invalid JSON" do
      user = insert(:user)
      _book = insert(:book)
      post = insert(:post, user: user, body: "Some post about books.")

      MockTogetherClient.put_response({:ok, "not valid json at all"})

      assert :ok == perform_job(PostBookAssociationWorker, %{post_id: post.id})

      associations = Blog.list_associations(post.id)
      assert associations == []
    end

    test "returns :ok when LLM returns empty array" do
      user = insert(:user)
      _book = insert(:book)
      post = insert(:post, user: user, body: "Nothing about books here.")

      MockTogetherClient.put_response({:ok, "[]"})

      assert :ok == perform_job(PostBookAssociationWorker, %{post_id: post.id})

      associations = Blog.list_associations(post.id)
      assert associations == []
    end

    test "returns :ok when post does not exist" do
      assert :ok ==
               perform_job(PostBookAssociationWorker, %{
                 post_id: Ecto.UUID.generate()
               })
    end

    test "retries on LLM failure" do
      user = insert(:user)
      _book = insert(:book)
      post = insert(:post, user: user, body: "Post content.")

      MockTogetherClient.put_response({:error, :circuit_open})

      assert {:error, :circuit_open} ==
               perform_job(PostBookAssociationWorker, %{post_id: post.id})
    end
  end
end
