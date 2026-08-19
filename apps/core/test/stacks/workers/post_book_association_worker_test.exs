defmodule Stacks.Workers.PostBookAssociationWorkerTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  alias Stacks.AI.MockTogetherClient
  alias Stacks.Blog
  alias Stacks.GDPR.Consent
  alias Stacks.Workers.PostBookAssociationWorker

  import Stacks.Factory

  setup do
    MockTogetherClient.clear()
    :ok
  end

  describe "perform/1" do
    test "associates books when LLM returns valid JSON" do
      user = consenting_author()
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
      user = consenting_author()
      _book = insert(:book)
      post = insert(:post, user: user, body: "Some post about books.")

      MockTogetherClient.put_response({:ok, "not valid json at all"})

      assert :ok == perform_job(PostBookAssociationWorker, %{post_id: post.id})

      associations = Blog.list_associations(post.id)
      assert associations == []
    end

    test "returns :ok when LLM returns empty array" do
      user = consenting_author()
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
      user = consenting_author()
      _book = insert(:book)
      post = insert(:post, user: user, body: "Post content.")

      MockTogetherClient.put_response({:error, :circuit_open})

      assert {:error, :circuit_open} ==
               perform_job(PostBookAssociationWorker, %{post_id: post.id})
    end
  end

  describe "the author's writing-assistant consent gates the third party" do
    @body "The night I finished Circe I sat with it for an hour before shelving it."

    test "without consent the post body never reaches the client seam" do
      user = insert(:user)
      _book = insert(:book, title: "Circe")
      post = insert(:post, user: user, body: @body)

      MockTogetherClient.put_response({:ok, Jason.encode!([])})
      attach_association_telemetry()

      assert :ok == perform_job(PostBookAssociationWorker, %{post_id: post.id})

      assert MockTogetherClient.sent() == []
      assert Blog.list_associations(post.id) == []
      assert_receive {:association_outcome, :no_consent}
    end

    test "with consent the same body does reach it — the gate, not a dead seam" do
      user = consenting_author()
      book = insert(:book, title: "Circe")
      post = insert(:post, user: user, body: @body)

      MockTogetherClient.put_response(
        {:ok, Jason.encode!([%{book_id: book.id, confidence: 0.9, reasoning: "Named"}])}
      )

      attach_association_telemetry()

      assert :ok == perform_job(PostBookAssociationWorker, %{post_id: post.id})

      assert [{:complete, prompt, _opts}] = MockTogetherClient.sent()
      assert prompt =~ @body
      assert [%{book_id: book_id}] = Blog.list_associations(post.id)
      assert book_id == book.id
      assert_receive {:association_outcome, :associated}
    end

    test "consent revoked after the fact leaves the associations already derived" do
      user = consenting_author()
      book = insert(:book, title: "Circe")
      post = insert(:post, user: user, body: @body)

      MockTogetherClient.put_response(
        {:ok, Jason.encode!([%{book_id: book.id, confidence: 0.9, reasoning: "Named"}])}
      )

      assert :ok == perform_job(PostBookAssociationWorker, %{post_id: post.id})
      assert {:ok, _user} = Consent.revoke_consent(user.id, "writing_assistant")

      assert [association] = Blog.list_associations(post.id)
      assert association.book_id == book.id
      assert association.reasoning == "Named"
    end

    test "a re-run after revocation sends nothing further" do
      user = consenting_author()
      book = insert(:book, title: "Circe")
      post = insert(:post, user: user, body: @body)

      MockTogetherClient.put_response(
        {:ok, Jason.encode!([%{book_id: book.id, confidence: 0.9, reasoning: "Named"}])}
      )

      assert :ok == perform_job(PostBookAssociationWorker, %{post_id: post.id})
      assert length(MockTogetherClient.sent()) == 1

      assert {:ok, _user} = Consent.revoke_consent(user.id, "writing_assistant")
      assert :ok == perform_job(PostBookAssociationWorker, %{post_id: post.id})

      assert length(MockTogetherClient.sent()) == 1
    end
  end

  defp consenting_author do
    user = insert(:user)
    {:ok, user} = Consent.grant_consent(user.id, "writing_assistant")
    user
  end

  defp attach_association_telemetry do
    test_pid = self()
    handler_id = "association-outcome-#{inspect(make_ref())}"

    :telemetry.attach(
      handler_id,
      [:stacks, :blog, :association],
      fn _event, _measurements, %{outcome: outcome}, _config ->
        send(test_pid, {:association_outcome, outcome})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
