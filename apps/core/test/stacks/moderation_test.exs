defmodule Stacks.ModerationTest do
  @moduledoc """
  Tests for Stacks.Moderation pipeline.

  The vision client is configured to Stacks.AI.MockClient in test.exs, so all
  calls to AIClient.call_vision/2 use the mock without hitting the network.

  ISBN resolution (Books.resolve_isbn) would otherwise make real HTTP calls to
  Open Library; the pipeline handles a resolution failure gracefully (empty
  subjects/bisac_codes), so no HTTP mocking is needed here.
  """

  # async: false — Core.DataCase's sandbox mode. Vision steering itself is
  # process-local (Stacks.AI.MockClient), so it is no longer what serialises
  # this file; the globally-attached telemetry handlers and the
  # :enrichment_confidence_threshold app-env swap are.
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.AI.VisionFixtures
  import Stacks.Factory

  alias Stacks.Books.MockHttpClient
  alias Stacks.Moderation

  # The pipeline now receives base64-encoded image data. Any non-empty string
  # works for unit tests since MockClient ignores the payload content.
  @test_image_b64 Base.encode64("fake image bytes")

  describe "run_pipeline/1 — happy path" do
    test "returns {:ok, [book]} when vision model confirms it is a book with valid ISBN" do
      context = %{
        image_b64: @test_image_b64,
        book_attrs: %{"title" => "The Great Gatsby"}
      }

      assert {:ok, %{resolved: [book], rejected: []}} = Moderation.run_pipeline(context)
      assert [edition | _] = book.editions
      assert edition.isbn == "9780743273565"
      assert book.visibility_tier in ["public", "age_gated"]
    end

    test "stores book with public tier when no adult BISAC codes are present" do
      context = %{
        image_b64: @test_image_b64,
        book_attrs: %{"title" => "A Peaceful Novel"}
      }

      assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(context)
      assert book.visibility_tier == "public"
    end

    test "creates a public book even when subjects would previously have gated it" do
      # The automatic subject→BISAC age-gate classifier was removed: a book is
      # age-gated only when a PERSON marks it (Books.set_visibility_tier/3),
      # never because code guessed from metadata. "romance" used to map to an
      # adult BISAC code and force-gate the book; it must now enter public.
      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{"ISBN:9780743273565" => %{"title" => "An Adult Romance", "subjects" => ["romance"]}}}
      )

      context = %{image_b64: @test_image_b64}
      assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(context)
      assert book.visibility_tier == "public"
    end

    test "returns existing book when ISBN already in database" do
      existing = insert(:book)
      insert(:book_edition, book: existing, isbn: "9780743273565")

      context = %{
        image_b64: @test_image_b64,
        book_attrs: %{"title" => "Should Not Matter"}
      }

      assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(context)
      assert book.id == existing.id
    end
  end

  describe "run_pipeline/1 — not_a_book path" do
    test "returns {:error, :not_a_book} when vision model says it is not a book" do
      with_vision(not_a_book(), fn ->
        context = %{image_b64: @test_image_b64}
        assert {:error, :not_a_book} = Moderation.run_pipeline(context)
      end)
    end
  end

  describe "run_pipeline/1 — isbn_not_found path" do
    test "returns {:error, :isbn_not_found} when vision model returns no ISBN" do
      with_vision(no_isbn(), fn ->
        context = %{image_b64: @test_image_b64}
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)
      end)
    end
  end

  describe "run_pipeline/1 — extraction error path" do
    test "returns error when vision extraction endpoint itself fails" do
      with_vision(service_error(), fn ->
        context = %{image_b64: @test_image_b64}
        assert {:error, _reason} = Moderation.run_pipeline(context)
      end)
    end
  end

  describe "run_pipeline/1 — compound title expansion" do
    test "splits 'Title A OR Title B' into two candidates and resolves both" do
      book_a = insert(:book)
      insert(:book_edition, book: book_a, isbn: "9780743273565")
      book_b = insert(:book)
      insert(:book_edition, book: book_b, isbn: "9780385333481")

      with_vision(compound_title(), fn ->
        context = %{image_b64: @test_image_b64}
        assert {:ok, %{resolved: books}} = Moderation.run_pipeline(context)
        assert length(books) == 2
      end)
    end
  end

  describe "run_pipeline/1 — unresolvable candidates" do
    test "returns {:error, :isbn_not_found} when candidates have no ISBN and nil title" do
      with_vision(no_resolvable(), fn ->
        context = %{image_b64: @test_image_b64}
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)
      end)
    end

    test "returns {:error, :isbn_not_found} when candidate title is empty string" do
      with_vision(empty_title(), fn ->
        context = %{image_b64: @test_image_b64}
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)
      end)
    end
  end

  describe "run_pipeline/1 — confidence threshold (Issue #167)" do
    # Low-confidence candidates inflate Google Books / Open Library traffic
    # and burn EnrichBookJob retry budget on guesses the vision model
    # itself flagged as weak. The pipeline now skips candidates with
    # confidence below the configured threshold (:core,
    # :enrichment_confidence_threshold — default 0.5) before any
    # external lookup or enqueue happens. Missing confidence is treated
    # as historical (process normally) to keep pre-prompt-v2 payloads working.

    setup do
      test_pid = self()
      handler_id = "test-skip-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [[:stacks, :enrichment, :candidate, :skipped]],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "high-confidence candidate (>= threshold) is processed normally" do
      with_vision(high_confidence(), fn ->
        # `book_attrs` supplies a title so the storage path succeeds even
        # though the test isbn_http_client returns no metadata.
        context = %{
          image_b64: @test_image_b64,
          book_attrs: %{"title" => "High Confidence Book"}
        }

        assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(context)
        assert [edition | _] = book.editions
        assert edition.isbn == "9780743273565"

        # No skip event should be emitted for a high-confidence candidate.
        refute_receive {:telemetry_event, [:stacks, :enrichment, :candidate, :skipped], _, _},
                       100
      end)
    end

    test "low-confidence candidate (< threshold) is skipped and emits telemetry" do
      with_vision(low_confidence(), fn ->
        context = %{image_b64: @test_image_b64}
        # All candidates were skipped — pipeline reports isbn_not_found.
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)

        # No EnrichBookJob should be enqueued for skipped candidates.
        refute_enqueued(worker: Stacks.Workers.EnrichBookJob)

        assert_receive {:telemetry_event, [:stacks, :enrichment, :candidate, :skipped],
                        %{count: 1, confidence: 0.4},
                        %{isbn: "9780743273565", reason: :low_confidence, threshold: 0.5}}
      end)
    end

    test "candidate with missing confidence is processed normally (historical)" do
      with_vision(no_confidence(), fn ->
        context = %{
          image_b64: @test_image_b64,
          book_attrs: %{"title" => "Historical Pre-v2"}
        }

        assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(context)
        assert [edition | _] = book.editions
        assert edition.isbn == "9780743273565"

        refute_receive {:telemetry_event, [:stacks, :enrichment, :candidate, :skipped], _, _},
                       100
      end)
    end

    test "candidate with explicit nil confidence is processed normally" do
      with_vision(nil_confidence(), fn ->
        context = %{
          image_b64: @test_image_b64,
          book_attrs: %{"title" => "Explicit Nil Confidence"}
        }

        assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(context)
        assert [edition | _] = book.editions
        assert edition.isbn == "9780743273565"

        refute_receive {:telemetry_event, [:stacks, :enrichment, :candidate, :skipped], _, _},
                       100
      end)
    end

    test "threshold is configurable via :core, :enrichment_confidence_threshold" do
      original_threshold = Application.get_env(:core, :enrichment_confidence_threshold)

      try do
        # Raise the bar above the candidate's confidence so the same
        # input that's accepted with the default threshold is now skipped.
        Application.put_env(:core, :enrichment_confidence_threshold, 0.9)

        with_vision(mid_confidence(), fn ->
          context = %{image_b64: @test_image_b64}
          assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)

          assert_receive {:telemetry_event, [:stacks, :enrichment, :candidate, :skipped],
                          %{count: 1, confidence: 0.7},
                          %{isbn: "9780743273565", reason: :low_confidence, threshold: 0.9}}
        end)
      after
        if original_threshold == nil do
          Application.delete_env(:core, :enrichment_confidence_threshold)
        else
          Application.put_env(:core, :enrichment_confidence_threshold, original_threshold)
        end
      end
    end

    test "telemetry metadata isbn falls back to nil when candidate has no potential_isbns" do
      with_vision(low_confidence_no_isbn(), fn ->
        context = %{image_b64: @test_image_b64}
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)

        assert_receive {:telemetry_event, [:stacks, :enrichment, :candidate, :skipped],
                        %{count: 1, confidence: 0.4},
                        %{isbn: nil, reason: :low_confidence, threshold: 0.5}}
      end)
    end
  end

  describe "run_pipeline/1 — excluded_books forwarding" do
    # Rejection-retry: when the user clicks "No, try again", the
    # controller enqueues a new IdentifyBookJob with the cumulative
    # list of already-rejected books. Moderation must forward that
    # list to the vision sidecar via the `:excluded_books` payload
    # key — the sidecar then steers the model away from those
    # candidates.

    setup do
      test_pid = self()
      handler_id = "test-excluded-#{System.unique_integer([:positive])}"
      Process.put(:test_pid, test_pid)

      {:ok, handler_id: handler_id, test_pid: test_pid}
    end

    test "forwards a non-empty list to the vision client payload" do
      with_vision(capture_payload(self()), fn ->
        context = %{
          image_b64: @test_image_b64,
          excluded_books: ["The Great Gatsby by F. Scott Fitzgerald"]
        }

        # We only care about what the payload looked like, not whether the
        # pipeline resolves. Capture and assert.
        _ = Moderation.run_pipeline(context)

        assert_receive {:vision_payload, payload}, 1_000
        assert payload[:excluded_books] == ["The Great Gatsby by F. Scott Fitzgerald"]
      end)
    end

    test "omits the key when excluded_books is empty or absent" do
      with_vision(capture_payload(self()), fn ->
        context = %{image_b64: @test_image_b64}
        _ = Moderation.run_pipeline(context)

        assert_receive {:vision_payload, payload}, 1_000
        refute Map.has_key?(payload, :excluded_books)
      end)
    end

    test "omits the key when excluded_books is an empty list" do
      with_vision(capture_payload(self()), fn ->
        context = %{image_b64: @test_image_b64, excluded_books: []}
        _ = Moderation.run_pipeline(context)

        assert_receive {:vision_payload, payload}, 1_000
        refute Map.has_key?(payload, :excluded_books)
      end)
    end
  end

  describe "run_pipeline/1 — excluded_isbns forwarding" do
    # Rejection-retry: when the controller resolves the cumulative
    # rejected_book_ids list to ISBNs, the IdentifyBookJob threads the
    # list into the moderation context as `:excluded_isbns`. Moderation
    # must apply the list in two places:
    #
    #   1. Direct-ISBN candidates from /analyze whose `potential_isbns`
    #      include an excluded ISBN are dropped BEFORE any DB/HTTP work.
    #   2. The title-search fallback receives the list via
    #      `ISBNResolver.search_by_title/4 :excluded_isbns` so OL/GB hits
    #      that map to an already-rejected book are skipped.

    # `book_attrs` is the negative control, not decoration: it makes the
    # candidate resolvable, so :isbn_not_found can ONLY be reached by the
    # exclusion dropping it. Without it these two tests reach :isbn_not_found
    # via a failed lookup and pass with `drop_excluded_isbn_candidates/2`
    # neutered — proven by mutation probe during Issue #331.
    test "VLM candidate whose direct ISBN matches an excluded entry is dropped" do
      # Single candidate with the excluded ISBN — dropping it leaves
      # no candidates to resolve, so the pipeline reports isbn_not_found.
      with_vision(single_isbn_candidate(), fn ->
        context = %{
          image_b64: @test_image_b64,
          excluded_isbns: ["9780743273565"],
          book_attrs: %{"title" => "Excluded Book"}
        }

        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)
      end)
    end

    test "exclusion is ISBN-10/13-form-insensitive: excluded 10 drops a candidate carrying the 13" do
      # `single_isbn_candidate()` yields "9780743273565" (ISBN-13);
      # "0743273567" is the same edition's ISBN-10. Canonicalisation
      # on both sides must still drop the candidate.
      with_vision(single_isbn_candidate(), fn ->
        context = %{
          image_b64: @test_image_b64,
          excluded_isbns: ["0743273567"],
          book_attrs: %{"title" => "Excluded By ISBN-10"}
        }

        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)
      end)
    end

    test "non-excluded VLM ISBN candidate is still resolved when excluded_isbns is set" do
      with_vision(single_isbn_candidate(), fn ->
        # `book_attrs` supplies a title so the storage path succeeds
        # without needing the test isbn_http_client to return metadata.
        # Mirrors the happy-path test setup higher in the file.
        context = %{
          image_b64: @test_image_b64,
          excluded_isbns: ["9999999999999"],
          book_attrs: %{"title" => "Non-Excluded Book"}
        }

        assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(context)
        assert [edition | _] = book.editions
        assert edition.isbn == "9780743273565"
      end)
    end
  end

  describe "run_pipeline/1 — null-ish author normalisation" do
    # Production bug: the VLM emitted the literal STRING "null" as the
    # author, which went out on the wire as `inauthor:null` (Google
    # Books) and `author=null` (Open Library) and was treated as real
    # author evidence by candidate scoring. Moderation must normalise
    # null-ish author strings to nil before calling
    # ISBNResolver.search_by_title/4 — nil authors are dropped from the
    # query params entirely.
    test "candidate with author=\"null\" reaches search_by_title with author=nil" do
      with_vision(null_author(), fn ->
        # Capture every URL the resolver requests. The test config
        # already wires :isbn_http_client to MockHttpClient; with no
        # registered responses every lookup misses, so the pipeline
        # ends in :isbn_not_found — we only care about the URLs.
        MockHttpClient.capture_requests()

        context = %{image_b64: @test_image_b64}
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)

        urls = collect_request_urls()
        assert urls != [], "expected the title-search to issue HTTP requests"

        # author="null" must be dropped: no author/inauthor param at all.
        refute Enum.any?(urls, &String.contains?(&1, "inauthor"))
        refute Enum.any?(urls, &String.contains?(&1, "null"))

        # And the raw_text normalisation must not corrupt keywords
        # ("TRAMP'S" → "tramps", never "scrystal").
        refute Enum.any?(urls, &String.contains?(&1, "scrystal"))
        assert Enum.any?(urls, &String.contains?(&1, "tramps"))
      end)
    end
  end

  defp collect_request_urls(acc \\ []) do
    receive do
      {MockHttpClient, :request, url} -> collect_request_urls([url | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "run_pipeline/1 — local-OCR fast path" do
    # When vision's /analyze short-circuits via the barcode pre-pass, it
    # returns `model_used: "local_ocr"`. We should skip the synchronous
    # OpenLibrary/Google Books lookup, use a placeholder title, and
    # enqueue EnrichBookJob to fill in metadata async.
    test "creates a placeholder book and enqueues EnrichBookJob when source is local_ocr" do
      with_vision(local_ocr(), fn ->
        context = %{image_b64: @test_image_b64}
        assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(context)
        # Placeholder title comes from "ISBN <isbn>".
        assert String.starts_with?(book.title, "ISBN ")

        # EnrichBookJob should have been enqueued for this ISBN.
        edition = List.first(book.editions)
        assert_enqueued(worker: Stacks.Workers.EnrichBookJob, args: %{"isbn" => edition.isbn})

        # The provenance is recorded ON THE ROW (#335 D1). Nothing external
        # confirmed this ISBN — only the barcode's own check digit did — and
        # that must stay auditable after enrichment overwrites the placeholder
        # title, which is the only place the fact used to live.
        assert edition.verification_source == "barcode_unverified"
      end)
    end

    test "the placeholder title stops being the only record of an unverified ISBN" do
      with_vision(local_ocr(), fn ->
        assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(%{image_b64: @test_image_b64})
        edition = List.first(book.editions)

        # Simulate what EnrichBookJob does on success: replace the placeholder.
        {:ok, _} =
          book
          |> Stacks.Books.book_changeset(%{"title" => "A Real Title"})
          |> Core.Repo.update()

        reloaded = Core.Repo.get!(Stacks.Books.BookEdition, edition.id)
        reloaded_book = Core.Repo.get!(Stacks.Books.Book, book.id)

        refute String.starts_with?(reloaded_book.title, "ISBN "),
               "precondition: enrichment has overwritten the placeholder title"

        assert reloaded.verification_source == "barcode_unverified",
               "the never-externally-verified fact must outlive the placeholder it used to be inferred from"
      end)
    end

    test "does NOT apply fast path when ISBN comes from the VLM (not local_ocr)" do
      # Same checksum-valid ISBN, but model_used is the VLM — we should
      # take the old OL/GB path. With the test mock returning {:ok, %{}}
      # for the HTTP lookup, metadata stays empty, title remains nil,
      # and the book is rejected (isbn_not_found).
      with_vision(vlm_extracted_isbn(), fn ->
        context = %{image_b64: @test_image_b64}
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)

        # No enrichment job enqueued — the fast path didn't fire.
        refute_enqueued(worker: Stacks.Workers.EnrichBookJob)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Vision scenarios
  # ---------------------------------------------------------------------------
  #
  # Each is a response the real seam (Stacks.AI.MockClient) is steered with —
  # no bespoke replacement client modules. All use the consolidated /analyze
  # shape (classification + books in one response).

  @gatsby "9780743273565"

  # A local_ocr barcode hit: full confidence, and `model_used` is what makes
  # Moderation take the fast path.
  defp local_ocr,
    do:
      books_with_isbns([@gatsby],
        confidence: 1.0,
        candidate_confidence: 1.0,
        model_used: "local_ocr"
      )

  # The same checksum-valid ISBN, but extracted by the VLM rather than the
  # barcode pre-pass — the fast path must NOT fire.
  defp vlm_extracted_isbn,
    do:
      books_with_isbns([@gatsby],
        confidence: 0.85,
        candidate_confidence: 0.8,
        model_used: "Qwen/Qwen2.5-VL-7B-Instruct"
      )

  # Two direct-ISBN candidates — the compound-title expansion path resolves both.
  defp compound_title, do: books_with_isbns([@gatsby, "9780385333481"])

  # Candidate with no ISBN and a nil title — title_fallback returns immediately.
  defp no_resolvable, do: book_response([book_candidate()])

  # Candidate with an empty-string title — the title_fallback trimming path.
  defp empty_title, do: book_response([book_candidate(title: "")])

  # -- Confidence-threshold scenarios (Issue #167) ----------------------------
  #
  # The gate reads the CANDIDATE's confidence, not the image-level one, so
  # these vary `:candidate_confidence` against a fixed image confidence.

  defp high_confidence, do: books_with_isbns([@gatsby], confidence: 0.95)

  defp low_confidence,
    do: books_with_isbns([@gatsby], confidence: 0.95, candidate_confidence: 0.4)

  defp mid_confidence,
    do: books_with_isbns([@gatsby], confidence: 0.95, candidate_confidence: 0.7)

  # No confidence key at all — the historical pre-prompt-v2 shape, which the
  # gate must treat as "process normally" rather than as zero.
  defp no_confidence,
    do: book_response([book_candidate(potential_isbns: [@gatsby])], confidence: 0.95)

  defp nil_confidence,
    do: books_with_isbns([@gatsby], confidence: 0.95, candidate_confidence: nil)

  # Low confidence AND no potential_isbns — the skip telemetry must report
  # isbn: nil rather than crashing on the empty list.
  defp low_confidence_no_isbn do
    book_response([book_candidate(title: "Some Title", confidence: 0.4)], confidence: 0.95)
  end

  # A single candidate with a known checksum-valid ISBN — used by the
  # excluded_isbns drop-candidate tests.
  defp single_isbn_candidate, do: books_with_isbns([@gatsby], confidence: 0.95)

  # Reproduces the production VLM payload that surfaced the null-author and
  # scrystal bugs: author is the literal string "null" and raw_text contains a
  # possessive apostrophe.
  defp null_author do
    book_response([
      book_candidate(
        title: "The Tramp's Crystal City",
        author: "null",
        raw_text: "THE TRAMP'S CRYSTAL CITY",
        confidence: 0.9
      )
    ])
  end
end
