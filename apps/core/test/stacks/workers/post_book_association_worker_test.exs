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

    test "a multi-association response persists every association" do
      # Four associations in one response, which the single-association happy
      # path above does not cover: it proves the decode, the mapping and the
      # persistence all hold for a list rather than a singleton.
      #
      # ⚠️ What this test does NOT cover, stated because I first wrote it
      # claiming otherwise and the probe caught me.
      #
      # It was written as a regression test for a real production defect:
      # `TogetherClient.parse_success_response/1` used to end in
      # `String.slice(content, 0, 500)` — a cap that mirrored the 500-character
      # limit on a review summary and belonged to the review-summary caller,
      # now deleted. In production that truncation corrupts THIS caller, which
      # asks for `max_tokens: 1024` and prompts for a JSON array of
      # `{book_id, confidence, reasoning}` over up to 200 candidate books: a
      # UUID alone is 36 characters, so a few associations exceed 500, the JSON
      # is cut mid-object, `Jason.decode/1` fails, and every association is
      # dropped while the worker still returns `:ok`.
      #
      # This test cannot see any of that. `complete/2` delegates to
      # `configured_client()`, which in test is `MockTogetherClient`, so the
      # real `parse_success_response/1` never runs — restoring the truncation
      # leaves this test green, which is how I know. The observable I would need
      # is an HTTP 200 body reaching the real parser, and there is no stub server
      # in this suite to produce one; `circuit_breakers_test.exs` points at the
      # real client only to force connection failures. Covering it means
      # building that stub, which is test infrastructure beyond a deletion's
      # scope, so the truncation removal rests on inspection: the review
      # validator is documented as the thing that "truncat[ed] to 500
      # characters", and the surviving cap lives on the changeset where it
      # belongs.
      user = consenting_author()
      books = for title <- ~w(Circe Kindred Beloved Ariel), do: insert(:book, title: title)
      post = insert(:post, user: user, body: "A long post about four books.")

      response =
        Jason.encode!(
          Enum.map(books, fn b ->
            %{
              book_id: b.id,
              confidence: 0.9,
              reasoning:
                "Discussed at length in the post, with the narrator returning to it repeatedly."
            }
          end)
        )

      MockTogetherClient.put_response({:ok, response})

      assert :ok == perform_job(PostBookAssociationWorker, %{post_id: post.id})

      associations = Blog.list_associations(post.id)

      assert length(associations) == 4,
             "expected all four associations to persist; got #{length(associations)}"
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
