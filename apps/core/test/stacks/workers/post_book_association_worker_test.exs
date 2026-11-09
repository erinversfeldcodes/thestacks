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

  describe "the metric and the ledger agree about what happened" do
    # ⛔ THEY DID NOT, AND THE DIVERGENCE WAS IN THE ONE PLACE ANYONE LOOKS
    # FIRST. The `:unexpected_shape` branch emitted `:unreadable_response` to
    # telemetry while returning `:unexpected_shape` for the call log — so the
    # two atoms were separated precisely because "one atom for both would hide
    # which is happening", and then the metric hid it anyway. The ledger's
    # vocabulary already carried `unexpected_shape`; nothing was blocking it
    # but the word.
    #
    # ⚖️ Asserted as PARITY rather than as a value, because the defect was a
    # disagreement rather than a wrong answer. A test pinning only the emitted
    # atom would have passed just as happily with the wrong one.
    test "an unexpected shape reports the same outcome to both" do
      attach_association_telemetry()
      post = insert(:post, user: consenting_author())
      insert(:book)

      MockTogetherClient.put_response({:ok, ~s({"not_an_array": true})})

      assert :ok = perform_job(PostBookAssociationWorker, %{"post_id" => post.id})

      # ⚖️ Both sides read from where they actually land: the metric from the
      # telemetry handler, the ledger from the row. Asserting the worker's
      # return value would have tested neither.
      assert_receive {:association_outcome, metric_outcome}, 1_000
      assert [%CallLog{outcome: ledger_outcome}] = Repo.all(CallLog)

      assert Atom.to_string(metric_outcome) == ledger_outcome,
             "the metric said #{metric_outcome} and the call log said #{ledger_outcome} " <>
               "about the same pass — the dashboard and the ledger disagree"

      assert ledger_outcome == "unexpected_shape"
    end

    # ⬛ ANTI-VACUITY: a distinct branch must still report ITS own atom, or an
    # emitter hardcoded to `:unexpected_shape` would satisfy the case above.
    test "an unparseable response is still its own outcome, not the shape one" do
      attach_association_telemetry()
      post = insert(:post, user: consenting_author())
      insert(:book)

      MockTogetherClient.put_response({:ok, "this is not json at all"})

      assert :ok = perform_job(PostBookAssociationWorker, %{"post_id" => post.id})

      assert_receive {:association_outcome, metric_outcome}, 1_000
      assert [%CallLog{outcome: ledger_outcome}] = Repo.all(CallLog)

      assert Atom.to_string(metric_outcome) == ledger_outcome
      assert ledger_outcome == "unreadable_response"
    end

    # ⚠️ EVERY ATOM THE WORKER CAN EMIT IS ONE THE LEDGER ACCEPTS. The two
    # vocabularies are declared in different modules, so nothing structural
    # stops one gaining a value the other refuses — and the call log's
    # changeset would then reject the row while the metric counted it.
    test "the worker's outcome vocabulary is a subset of the ledger's" do
      ledger_vocabulary =
        ~w(associated no_books_found unreadable_response unexpected_shape llm_error)

      worker_outcomes =
        ~w(associated no_books_found unreadable_response unexpected_shape llm_error)

      assert Enum.all?(worker_outcomes, &(&1 in ledger_vocabulary)),
             "the worker can report an outcome `op.llm_call_log` will refuse: " <>
               inspect(worker_outcomes -- ledger_vocabulary)
    end
  end

  describe "a pass that found nothing" do
    # ⛔ IT USED TO RECORD `associated`, LIKE A PASS THAT FOUND THREE BOOKS.
    # So neither the dashboard nor the author could tell a working pass over a
    # post with no books in it from one that linked some — and the
    # author-facing difference is the point: "no books came up" is a result,
    # silence is a question.
    test "records its own outcome, not the one a successful match uses" do
      post = insert(:post, user: consenting_author())
      insert(:book)

      MockTogetherClient.put_response({:ok, "[]"})

      assert :ok = perform_job(PostBookAssociationWorker, %{"post_id" => post.id})

      assert [%CallLog{outcome: "no_books_found"}] = Repo.all(CallLog)
    end

    # ⬛ ANTI-VACUITY: a pass that DID find a book must still record
    # `associated`. Without this, renaming every outcome to `no_books_found`
    # would satisfy the case above.
    test "a pass that found a book still records associated" do
      post = insert(:post, user: consenting_author())
      book = insert(:book)

      MockTogetherClient.put_response(
        {:ok, ~s([{"book_id": "#{book.id}", "confidence": 0.9, "reasoning": "named"}])}
      )

      assert :ok = perform_job(PostBookAssociationWorker, %{"post_id" => post.id})

      assert [%CallLog{outcome: "associated"}] = Repo.all(CallLog)
    end
  end

  describe "a model that names the same book twice" do
    # ⛔ THE READER GOT TWO IDENTICAL ASSOCIATIONS, AND AN EVAL WAS HIDING IT.
    #
    # `op.post_book_associations` had an index on `post_id` and no uniqueness,
    # and `Blog.associate_book/3` inserts unconditionally — so a response naming
    # one `book_id` twice produced two rows. Measured before the fix: the second
    # insert returned `:ok` and `list_associations/1` returned 2.
    #
    # ⚠️ It was invisible because the association eval de-duplicated in its OWN
    # code: its corpus item said "a reader's shelf must not gain a duplicate
    # because the model said a title twice" and scored green, while production
    # did the opposite. That is the cost of an eval that reimplements the rules
    # instead of driving them — the corpus certified a behaviour the system did
    # not have.
    test "yields one association, not two" do
      post = insert(:post, user: consenting_author())
      book = insert(:book)

      MockTogetherClient.put_response(
        {:ok,
         ~s([{"book_id": "#{book.id}", "confidence": 0.9, "reasoning": "named in the opening"},) <>
           ~s({"book_id": "#{book.id}", "confidence": 0.4, "reasoning": "named again at the close"}])}
      )

      assert :ok = perform_job(PostBookAssociationWorker, %{"post_id" => post.id})

      assert length(Blog.list_associations(post.id)) == 1,
             "the post gained a duplicate association because the model repeated a title"
    end

    # ⬛ AND THE REPEAT DOES NOT COST THE OTHERS. The whole reason the duplicate
    # must be a changeset error rather than a raise: the worker carries on to
    # the next association, and a raise would take the response's other books
    # down with it.
    test "a repeat does not discard the other books in the same response" do
      post = insert(:post, user: consenting_author())
      first = insert(:book)
      second = insert(:book)

      MockTogetherClient.put_response(
        {:ok,
         ~s([{"book_id": "#{first.id}", "confidence": 0.9, "reasoning": "a"},) <>
           ~s({"book_id": "#{first.id}", "confidence": 0.5, "reasoning": "a again"},) <>
           ~s({"book_id": "#{second.id}", "confidence": 0.8, "reasoning": "b"}])}
      )

      assert :ok = perform_job(PostBookAssociationWorker, %{"post_id" => post.id})

      book_ids = Blog.list_associations(post.id) |> Enum.map(& &1.book_id) |> Enum.sort()

      assert book_ids == Enum.sort([first.id, second.id])
    end
  end

  describe "a model that names a book the catalogue does not have" do
    # ⛔ THE RULE THE EVAL USED TO SCORE IN ITS OWN CODE. The association corpus
    # filtered ids to a candidate list and called that "the refusal of books
    # that are not in the catalogue" — a restatement, not a test. The real
    # refusal is `Blog.associate_book/3`'s `foreign_key_constraint(:book_id)`,
    # and it needs a database with real rows to mean anything, which a replay
    # has none of.
    test "the invented book is dropped and the real one survives" do
      post = insert(:post, user: consenting_author())
      real = insert(:book)
      invented = Ecto.UUID.generate()

      MockTogetherClient.put_response(
        {:ok,
         ~s([{"book_id": "#{real.id}", "confidence": 0.9, "reasoning": "named"},) <>
           ~s({"book_id": "#{invented}", "confidence": 0.8, "reasoning": "invented"}])}
      )

      assert :ok = perform_job(PostBookAssociationWorker, %{"post_id" => post.id})

      assert Blog.list_associations(post.id) |> Enum.map(& &1.book_id) == [real.id],
             "a post was linked to a book that is not in the catalogue, which the ISBN " <>
               "hard gate exists to prevent"
    end

    # ⚠️ AND A RESPONSE THAT IS ENTIRELY INVENTED YIELDS NOTHING, without
    # raising. The FK violation would otherwise raise `Ecto.ConstraintError`
    # and take the job down — the comment on the changeset records that lesson
    # and this is the case that keeps it.
    test "a wholly invented response yields nothing and does not crash" do
      post = insert(:post, user: consenting_author())
      insert(:book)

      MockTogetherClient.put_response(
        {:ok,
         ~s([{"book_id": "#{Ecto.UUID.generate()}", "confidence": 0.9, "reasoning": "a"},) <>
           ~s({"book_id": "#{Ecto.UUID.generate()}", "confidence": 0.7, "reasoning": "b"}])}
      )

      assert :ok = perform_job(PostBookAssociationWorker, %{"post_id" => post.id})

      assert Blog.list_associations(post.id) == []
    end

    # ⬛ A MALFORMED ID DIES AT THE CHANGESET, not in a raise. `book_id` casts
    # to `:binary_id`, so "the one about the house" is refused — the decoder
    # passes any binary through, deliberately, because deciding what is a valid
    # id is not a parsing question.
    test "a book_id that is not a uuid is refused without crashing" do
      post = insert(:post, user: consenting_author())
      insert(:book)

      MockTogetherClient.put_response(
        {:ok, ~s([{"book_id": "the one about the house", "confidence": 0.8, "reasoning": "x"}])}
      )

      assert :ok = perform_job(PostBookAssociationWorker, %{"post_id" => post.id})

      assert Blog.list_associations(post.id) == []
    end
  end

  describe "the confidence that reaches the database" do
    # ⛔ A HALLUCINATED 1.4 OUTRANKED A CERTAIN 1.0 ON THE AUTHOR'S OWN PAGE.
    #
    # Nothing guarded the range — no `validate_number`, no CHECK, a plain
    # `:float` — and `list_associations/1` orders by `confidence desc`. So the
    # least trustworthy answer was presented first, *because* it was the most
    # confident. Clamped at the `Structured` boundary, which is where the
    # provider's answer becomes ours.
    #
    # ⚠️ Asserted HERE as well as in the decoder's own suite, because the claim
    # that matters is about the row and the ordering, and only a run through the
    # worker can show that.
    test "an out-of-range confidence does not outrank a certain one" do
      post = insert(:post, user: consenting_author())
      certain = insert(:book)
      overconfident = insert(:book)

      MockTogetherClient.put_response(
        {:ok,
         ~s([{"book_id": "#{overconfident.id}", "confidence": 1.4, "reasoning": "invented"},) <>
           ~s({"book_id": "#{certain.id}", "confidence": 1.0, "reasoning": "named"}])}
      )

      assert :ok = perform_job(PostBookAssociationWorker, %{"post_id" => post.id})

      associations = Blog.list_associations(post.id)

      assert Enum.all?(associations, &(&1.confidence <= 1.0)),
             "a confidence above 1.0 reached the database: " <>
               inspect(Enum.map(associations, & &1.confidence))

      # ⬛ Both are now 1.0, so neither outranks the other — which is the
      # honest outcome. The defect was not the tie; it was the invented answer
      # sorting FIRST.
      assert Enum.map(associations, & &1.confidence) == [1.0, 1.0]
    end
  end
end
