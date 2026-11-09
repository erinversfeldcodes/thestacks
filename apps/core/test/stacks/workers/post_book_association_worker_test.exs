defmodule Stacks.Workers.PostBookAssociationWorkerTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  alias Core.Repo
  alias Stacks.AI.CallLog
  alias Stacks.AI.MockTogetherClient
  alias Stacks.AI.Structured
  alias Stacks.Blog
  alias Stacks.GDPR.Consent
  alias Stacks.Test.Fixtures.LlmAssociationResponses, as: Responses
  alias Stacks.Workers.PostBookAssociationWorker

  import Stacks.Factory

  setup do
    MockTogetherClient.clear()
    :ok
  end

  describe "the shape the model actually sends" do
    @moduletag :association_contract

    # ⛔ EVERY CASE HERE WOULD HAVE FAILED BEFORE `Stacks.AI.Structured`, AND THE
    # SUITE WAS GREEN THROUGHOUT. The existing cases feed `Jason.encode!/1` —
    # bare, unfenced JSON that the model does not send. MEASURED against the live
    # model with this worker's own prompt: 3 of 3 responses came back FENCED,
    # 744-782 characters, and `Jason.decode/1` failed on the first character of
    # every one. The worker dropped the associations and logged a warning.
    #
    # ⚖️ So the old tests were not wrong, they were testing a shape nothing
    # produces. That is the gap a contract closes, and these are the cases that
    # hold it closed.

    test "a fenced response from the model persists its associations" do
      user = consenting_author()
      first = insert(:book, title: "To the Lighthouse")
      second = insert(:book, title: "The Waves")
      post = insert(:post, user: user, body: "On Woolf, and what to read next.")

      # The captured shape, with this test's real book ids substituted in.
      response =
        Responses.fenced_three()
        |> String.replace("9d1f0c3a-5e4b-4a21-8f07-2c6b9ad3e114", first.id)
        |> String.replace("3b7e2d14-9a6c-4f58-b013-7e8a1c45d920", second.id)

      MockTogetherClient.put_response({:ok, response})

      assert :ok == perform_job(PostBookAssociationWorker, %{post_id: post.id})

      associations = Blog.list_associations(post.id)

      # ⚠️ Two, not three: the third id in the fixture belongs to no book here,
      # so `Blog.associate_book/3` refuses it. That is the right behaviour and
      # worth asserting — a model naming a book outside the catalogue must not
      # create a row.
      assert length(associations) == 2

      assert Enum.map(associations, & &1.book_id) |> Enum.sort() ==
               Enum.sort([first.id, second.id])

      lighthouse = Enum.find(associations, &(&1.book_id == first.id))
      assert lighthouse.confidence == 0.92
      assert lighthouse.reasoning =~ "lighthouse"

      # ⛔ THE WRITER, WHICH NOTHING ASSERTED. A probe replacing `Repo.insert/1`
      # in `record_call/5` with a pass-through left 120 tests green: the
      # migration, the schema, the 8 KB bound and the retention were all proven
      # while the thing that fills the table was not. `CallLogTest` builds its
      # rows by hand, so it cannot see this.
      #
      # ⚠️ It matters because the eval corpus is model OUTPUTS. A silently empty
      # log is discovered weeks later, by whoever goes looking for a dataset
      # that was never being collected.
      assert [%CallLog{} = logged] = Repo.all(CallLog)
      assert logged.post_id == post.id
      assert logged.outcome == "associated"
      # ⚠️ TRIMMED, because that is what the client hands back. The real
      # success path ends in `String.trim/1`, so a trailing newline in the
      # canned fixture never reaches a caller in production — and asserting the
      # untrimmed string would pin behaviour the shipped code does not have.
      assert logged.raw_response == String.trim(response)
      assert logged.prompt_sha256 != nil
    end

    test "a bare ``` fence works too, because the model varies it" do
      user = consenting_author()
      book = insert(:book, title: "Inherited Libraries")
      post = insert(:post, user: user, body: "What my father's shelves held.")

      response =
        Responses.fenced_two_bare_fence()
        |> String.replace("7f2c9b31-8e05-4d6a-9c14-3a7e5d2b0f88", book.id)

      MockTogetherClient.put_response({:ok, response})

      assert :ok == perform_job(PostBookAssociationWorker, %{post_id: post.id})
      assert [assoc] = Blog.list_associations(post.id)
      assert assoc.book_id == book.id
      assert assoc.confidence == 0.88
    end

    test "a fenced empty array is an answer, and persists nothing" do
      user = consenting_author()
      post = insert(:post, user: user, body: "A post about gardening.")

      MockTogetherClient.put_response({:ok, Responses.fenced_empty()})

      assert :ok == perform_job(PostBookAssociationWorker, %{post_id: post.id})
      assert Blog.list_associations(post.id) == []
    end

    # ⛔ THE M1 PROBE, AS AN ASSERTION. M1 was removing the 500-character
    # truncation from `complete/2`, which left the whole suite green — nothing
    # guarded it. The truncation is gone now, so the probe that matters is the
    # INVERSE: a response cut at 500 characters must be refused rather than
    # silently dropped, and this is the case that notices.
    test "a response truncated at 500 characters associates nothing" do
      user = consenting_author()
      book = insert(:book, title: "To the Lighthouse")
      post = insert(:post, user: user, body: "On Woolf.")

      truncated =
        Responses.fenced_three()
        |> String.replace("9d1f0c3a-5e4b-4a21-8f07-2c6b9ad3e114", book.id)
        |> String.slice(0, 500)

      MockTogetherClient.put_response({:ok, truncated})

      assert :ok == perform_job(PostBookAssociationWorker, %{post_id: post.id})

      assert Blog.list_associations(post.id) == [],
             "a half-read response must not produce associations — the truncation this " <>
               "guards against cut the JSON mid-object and the worker parsed the fragment"
    end
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

      assert [{:complete, prompt, opts}] = MockTogetherClient.sent()
      assert prompt =~ @body

      # ⛔ THE PRODUCTION CALL SITE ASKS FOR A SHAPE, and nothing asserted it
      # until a probe removed `schema:` from the worker's opts and left 94 tests
      # green. The measured defect — 3 of 3 responses fenced — is fixed AT this
      # call site, so an unguarded call site is an unguarded fix. The
      # observation point was already here, one underscore away.
      assert Keyword.fetch!(opts, :schema) == Structured.association_schema(),
             "the worker must ask the provider for the association schema; without it " <>
               "the model answers in whatever shape it likes, which is the defect this " <>
               "whole boundary was rebuilt around"

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
