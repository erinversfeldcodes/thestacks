defmodule Stacks.ModerationTest do
  @moduledoc """
  Tests for Stacks.Moderation pipeline.

  The vision client is configured to Stacks.AI.MockClient in test.exs, so all
  calls to AIClient.call_vision/2 use the mock without hitting the network.

  ISBN resolution (Books.resolve_isbn) would otherwise make real HTTP calls to
  Open Library; the pipeline handles a resolution failure gracefully (empty
  subjects/bisac_codes), so no HTTP mocking is needed here.
  """

  # async: false — tests use Application.put_env to swap the vision client,
  # which is global process state and not safe for concurrent test execution.
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

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
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.NotABookClient)

        context = %{image_b64: @test_image_b64}
        assert {:error, :not_a_book} = Moderation.run_pipeline(context)
      after
        Application.put_env(:core, :vision_client, original)
      end
    end
  end

  describe "run_pipeline/1 — isbn_not_found path" do
    test "returns {:error, :isbn_not_found} when vision model returns no ISBN" do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.NoIsbnClient)

        context = %{image_b64: @test_image_b64}
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)
      after
        Application.put_env(:core, :vision_client, original)
      end
    end
  end

  describe "run_pipeline/1 — extraction error path" do
    test "returns error when vision extraction endpoint itself fails" do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.ExtractionErrorClient)

        context = %{image_b64: @test_image_b64}
        assert {:error, _reason} = Moderation.run_pipeline(context)
      after
        Application.put_env(:core, :vision_client, original)
      end
    end
  end

  describe "run_pipeline/1 — compound title expansion" do
    test "splits 'Title A OR Title B' into two candidates and resolves both" do
      book_a = insert(:book)
      insert(:book_edition, book: book_a, isbn: "9780743273565")
      book_b = insert(:book)
      insert(:book_edition, book: book_b, isbn: "9780385333481")
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.CompoundTitleClient)

        context = %{image_b64: @test_image_b64}
        assert {:ok, %{resolved: books}} = Moderation.run_pipeline(context)
        assert length(books) == 2
      after
        Application.put_env(:core, :vision_client, original)
      end
    end
  end

  describe "run_pipeline/1 — unresolvable candidates" do
    test "returns {:error, :isbn_not_found} when candidates have no ISBN and nil title" do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.NoResolvableClient)

        context = %{image_b64: @test_image_b64}
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)
      after
        Application.put_env(:core, :vision_client, original)
      end
    end

    test "returns {:error, :isbn_not_found} when candidate title is empty string" do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.EmptyTitleClient)

        context = %{image_b64: @test_image_b64}
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)
      after
        Application.put_env(:core, :vision_client, original)
      end
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
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.HighConfidenceClient)

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
      after
        Application.put_env(:core, :vision_client, original)
      end
    end

    test "low-confidence candidate (< threshold) is skipped and emits telemetry" do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.LowConfidenceClient)

        context = %{image_b64: @test_image_b64}
        # All candidates were skipped — pipeline reports isbn_not_found.
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)

        # No EnrichBookJob should be enqueued for skipped candidates.
        refute_enqueued(worker: Stacks.Workers.EnrichBookJob)

        assert_receive {:telemetry_event, [:stacks, :enrichment, :candidate, :skipped],
                        %{count: 1, confidence: 0.4},
                        %{isbn: "9780743273565", reason: :low_confidence, threshold: 0.5}}
      after
        Application.put_env(:core, :vision_client, original)
      end
    end

    test "candidate with missing confidence is processed normally (historical)" do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.NoConfidenceClient)

        context = %{
          image_b64: @test_image_b64,
          book_attrs: %{"title" => "Historical Pre-v2"}
        }

        assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(context)
        assert [edition | _] = book.editions
        assert edition.isbn == "9780743273565"

        refute_receive {:telemetry_event, [:stacks, :enrichment, :candidate, :skipped], _, _},
                       100
      after
        Application.put_env(:core, :vision_client, original)
      end
    end

    test "candidate with explicit nil confidence is processed normally" do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.NilConfidenceClient)

        context = %{
          image_b64: @test_image_b64,
          book_attrs: %{"title" => "Explicit Nil Confidence"}
        }

        assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(context)
        assert [edition | _] = book.editions
        assert edition.isbn == "9780743273565"

        refute_receive {:telemetry_event, [:stacks, :enrichment, :candidate, :skipped], _, _},
                       100
      after
        Application.put_env(:core, :vision_client, original)
      end
    end

    test "threshold is configurable via :core, :enrichment_confidence_threshold" do
      original_client = Application.get_env(:core, :vision_client)
      original_threshold = Application.get_env(:core, :enrichment_confidence_threshold)

      try do
        # Raise the bar above the candidate's confidence so the same
        # input that's accepted with the default threshold is now skipped.
        Application.put_env(:core, :enrichment_confidence_threshold, 0.9)
        Application.put_env(:core, :vision_client, __MODULE__.MidConfidenceClient)

        context = %{image_b64: @test_image_b64}
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)

        assert_receive {:telemetry_event, [:stacks, :enrichment, :candidate, :skipped],
                        %{count: 1, confidence: 0.7},
                        %{isbn: "9780743273565", reason: :low_confidence, threshold: 0.9}}
      after
        Application.put_env(:core, :vision_client, original_client)

        if original_threshold == nil do
          Application.delete_env(:core, :enrichment_confidence_threshold)
        else
          Application.put_env(:core, :enrichment_confidence_threshold, original_threshold)
        end
      end
    end

    test "telemetry metadata isbn falls back to nil when candidate has no potential_isbns" do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.LowConfidenceNoIsbnClient)

        context = %{image_b64: @test_image_b64}
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)

        assert_receive {:telemetry_event, [:stacks, :enrichment, :candidate, :skipped],
                        %{count: 1, confidence: 0.4},
                        %{isbn: nil, reason: :low_confidence, threshold: 0.5}}
      after
        Application.put_env(:core, :vision_client, original)
      end
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
      original = Application.get_env(:core, :vision_client)
      test_pid = self()
      Process.put(:moderation_capture_pid, test_pid)
      :persistent_term.put({__MODULE__, :capture_pid}, test_pid)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.CapturePayloadClient)

        context = %{
          image_b64: @test_image_b64,
          excluded_books: ["The Great Gatsby by F. Scott Fitzgerald"]
        }

        # MockClient returns Gatsby; we only care about what the payload
        # looked like, not whether the pipeline resolves. Capture and assert.
        _ = Moderation.run_pipeline(context)

        assert_receive {:vision_payload, payload}, 1_000
        assert payload[:excluded_books] == ["The Great Gatsby by F. Scott Fitzgerald"]
      after
        :persistent_term.erase({__MODULE__, :capture_pid})
        Application.put_env(:core, :vision_client, original)
      end
    end

    test "omits the key when excluded_books is empty or absent" do
      original = Application.get_env(:core, :vision_client)
      test_pid = self()
      :persistent_term.put({__MODULE__, :capture_pid}, test_pid)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.CapturePayloadClient)

        context = %{image_b64: @test_image_b64}
        _ = Moderation.run_pipeline(context)

        assert_receive {:vision_payload, payload}, 1_000
        refute Map.has_key?(payload, :excluded_books)
      after
        :persistent_term.erase({__MODULE__, :capture_pid})
        Application.put_env(:core, :vision_client, original)
      end
    end

    test "omits the key when excluded_books is an empty list" do
      original = Application.get_env(:core, :vision_client)
      test_pid = self()
      :persistent_term.put({__MODULE__, :capture_pid}, test_pid)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.CapturePayloadClient)

        context = %{image_b64: @test_image_b64, excluded_books: []}
        _ = Moderation.run_pipeline(context)

        assert_receive {:vision_payload, payload}, 1_000
        refute Map.has_key?(payload, :excluded_books)
      after
        :persistent_term.erase({__MODULE__, :capture_pid})
        Application.put_env(:core, :vision_client, original)
      end
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

    test "VLM candidate whose direct ISBN matches an excluded entry is dropped" do
      original = Application.get_env(:core, :vision_client)

      try do
        # Single candidate with the excluded ISBN — dropping it leaves
        # no candidates to resolve, so the pipeline reports isbn_not_found.
        Application.put_env(:core, :vision_client, __MODULE__.SingleIsbnCandidateClient)

        context = %{
          image_b64: @test_image_b64,
          excluded_isbns: ["9780743273565"]
        }

        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)
      after
        Application.put_env(:core, :vision_client, original)
      end
    end

    test "exclusion is ISBN-10/13-form-insensitive: excluded 10 drops a candidate carrying the 13" do
      original = Application.get_env(:core, :vision_client)

      try do
        # SingleIsbnCandidateClient yields "9780743273565" (ISBN-13);
        # "0743273567" is the same edition's ISBN-10. Canonicalisation
        # on both sides must still drop the candidate.
        Application.put_env(:core, :vision_client, __MODULE__.SingleIsbnCandidateClient)

        context = %{
          image_b64: @test_image_b64,
          excluded_isbns: ["0743273567"]
        }

        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)
      after
        Application.put_env(:core, :vision_client, original)
      end
    end

    test "non-excluded VLM ISBN candidate is still resolved when excluded_isbns is set" do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.SingleIsbnCandidateClient)

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
      after
        Application.put_env(:core, :vision_client, original)
      end
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
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.NullAuthorClient)

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
      after
        Application.put_env(:core, :vision_client, original)
      end
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
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.LocalOcrClient)

        context = %{image_b64: @test_image_b64}
        assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(context)
        # Placeholder title comes from "ISBN <isbn>".
        assert String.starts_with?(book.title, "ISBN ")

        # EnrichBookJob should have been enqueued for this ISBN.
        isbn = List.first(book.editions).isbn
        assert_enqueued(worker: Stacks.Workers.EnrichBookJob, args: %{"isbn" => isbn})
      after
        Application.put_env(:core, :vision_client, original)
      end
    end

    test "does NOT apply fast path when ISBN comes from the VLM (not local_ocr)" do
      # Same checksum-valid ISBN, but model_used is the VLM — we should
      # take the old OL/GB path. With the test mock returning {:ok, %{}}
      # for the HTTP lookup, metadata stays empty, title remains nil,
      # and the book is rejected (isbn_not_found).
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.VlmExtractedIsbnClient)

        context = %{image_b64: @test_image_b64}
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)

        # No enrichment job enqueued — the fast path didn't fire.
        refute_enqueued(worker: Stacks.Workers.EnrichBookJob)
      after
        Application.put_env(:core, :vision_client, original)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Inline mock modules for specific failure scenarios
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Inline mock modules for specific failure scenarios. Each returns the
  # consolidated /analyze shape (classification + books in one response).
  # ---------------------------------------------------------------------------

  defmodule LocalOcrClient do
    @moduledoc "Vision client that simulates a local_ocr barcode hit."
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("analyze", _payload),
      do:
        {:ok,
         %{
           "classification" => "CLASSIFICATION_RESULT_BOOK",
           "confidence" => 1.0,
           "books" => [
             %{
               "title" => nil,
               "author" => nil,
               # Checksum-valid ISBN — Gatsby.
               "potential_isbns" => ["9780743273565"],
               "raw_text" => nil,
               "confidence" => 1.0
             }
           ],
           "model_used" => "local_ocr"
         }}

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule VlmExtractedIsbnClient do
    @moduledoc "Vision client that returns a checksum-valid ISBN from the VLM, not barcode OCR."
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("analyze", _payload),
      do:
        {:ok,
         %{
           "classification" => "CLASSIFICATION_RESULT_BOOK",
           "confidence" => 0.85,
           "books" => [
             %{
               "title" => nil,
               "author" => nil,
               # Same checksum-valid ISBN as the local_ocr test.
               "potential_isbns" => ["9780743273565"],
               "raw_text" => nil,
               "confidence" => 0.8
             }
           ],
           "model_used" => "Qwen/Qwen2.5-VL-7B-Instruct"
         }}

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule NotABookClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("analyze", _payload),
      do:
        {:ok,
         %{
           "classification" => "CLASSIFICATION_RESULT_NOT_BOOK",
           "confidence" => 0.95,
           "books" => [],
           "model_used" => "mock"
         }}

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule NoIsbnClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour

    # BOOK + empty books — triggers :isbn_not_found in Moderation.analyze/2.
    @impl true
    def call_vision("analyze", _payload),
      do:
        {:ok,
         %{
           "classification" => "CLASSIFICATION_RESULT_BOOK",
           "confidence" => 0.9,
           "books" => [],
           "model_used" => "mock"
         }}

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule ExtractionErrorClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour

    # Service-unavailable at the analyze call — same failure mode the old
    # ExtractionErrorClient exercised against /extract_isbn.
    @impl true
    def call_vision("analyze", _payload), do: {:error, :service_unavailable}
    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule CompoundTitleClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("analyze", _payload) do
      {:ok,
       %{
         "classification" => "CLASSIFICATION_RESULT_BOOK",
         "confidence" => 0.9,
         "books" => [
           %{
             "title" => nil,
             "author" => nil,
             "potential_isbns" => ["9780743273565"],
             "raw_text" => nil,
             "confidence" => 0.9
           },
           %{
             "title" => nil,
             "author" => nil,
             "potential_isbns" => ["9780385333481"],
             "raw_text" => nil,
             "confidence" => 0.9
           }
         ],
         "model_used" => "mock"
       }}
    end

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule NoResolvableClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour

    # Candidate with no ISBN and nil title — title_fallback returns immediately.
    @impl true
    def call_vision("analyze", _payload) do
      {:ok,
       %{
         "classification" => "CLASSIFICATION_RESULT_BOOK",
         "confidence" => 0.9,
         "books" => [
           %{
             "title" => nil,
             "author" => nil,
             "potential_isbns" => [],
             "raw_text" => nil
           }
         ],
         "model_used" => "mock"
       }}
    end

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule EmptyTitleClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour

    # Candidate with empty-string title — exercises the title_fallback
    # trimming path.
    @impl true
    def call_vision("analyze", _payload) do
      {:ok,
       %{
         "classification" => "CLASSIFICATION_RESULT_BOOK",
         "confidence" => 0.9,
         "books" => [
           %{
             "title" => "",
             "author" => nil,
             "potential_isbns" => [],
             "raw_text" => nil
           }
         ],
         "model_used" => "mock"
       }}
    end

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  # ---------------------------------------------------------------------------
  # Inline mock modules for confidence-threshold tests (Issue #167).
  # ---------------------------------------------------------------------------

  defmodule HighConfidenceClient do
    @moduledoc "Candidate confidence above the default 0.5 threshold."
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("analyze", _payload) do
      {:ok,
       %{
         "classification" => "CLASSIFICATION_RESULT_BOOK",
         "confidence" => 0.95,
         "books" => [
           %{
             "title" => nil,
             "author" => nil,
             "potential_isbns" => ["9780743273565"],
             "raw_text" => nil,
             "confidence" => 0.9
           }
         ],
         "model_used" => "mock"
       }}
    end

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule LowConfidenceClient do
    @moduledoc """
    Candidate confidence below the #167 0.5 threshold. Exercises the
    per-candidate skip gate which fires before any external lookup or
    EnrichBookJob enqueue.
    """
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("analyze", _payload) do
      {:ok,
       %{
         "classification" => "CLASSIFICATION_RESULT_BOOK",
         "confidence" => 0.95,
         "books" => [
           %{
             "title" => nil,
             "author" => nil,
             "potential_isbns" => ["9780743273565"],
             "raw_text" => nil,
             "confidence" => 0.4
           }
         ],
         "model_used" => "mock"
       }}
    end

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule NoConfidenceClient do
    @moduledoc "Candidate payload with no confidence key — historical shape."
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("analyze", _payload) do
      {:ok,
       %{
         "classification" => "CLASSIFICATION_RESULT_BOOK",
         "confidence" => 0.95,
         "books" => [
           %{
             "title" => nil,
             "author" => nil,
             "potential_isbns" => ["9780743273565"],
             "raw_text" => nil
           }
         ],
         "model_used" => "mock"
       }}
    end

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule NilConfidenceClient do
    @moduledoc "Candidate with explicit nil confidence."
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("analyze", _payload) do
      {:ok,
       %{
         "classification" => "CLASSIFICATION_RESULT_BOOK",
         "confidence" => 0.95,
         "books" => [
           %{
             "title" => nil,
             "author" => nil,
             "potential_isbns" => ["9780743273565"],
             "raw_text" => nil,
             "confidence" => nil
           }
         ],
         "model_used" => "mock"
       }}
    end

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule MidConfidenceClient do
    @moduledoc "Candidate confidence between 0.5 and 0.9 — exercises configurable threshold."
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("analyze", _payload) do
      {:ok,
       %{
         "classification" => "CLASSIFICATION_RESULT_BOOK",
         "confidence" => 0.95,
         "books" => [
           %{
             "title" => nil,
             "author" => nil,
             "potential_isbns" => ["9780743273565"],
             "raw_text" => nil,
             "confidence" => 0.7
           }
         ],
         "model_used" => "mock"
       }}
    end

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule CapturePayloadClient do
    @moduledoc """
    Vision client that snapshots the outgoing payload (via the test PID
    stored in persistent_term) and then short-circuits with
    `:isbn_not_found` so the pipeline returns quickly. Used by the
    `excluded_books forwarding` tests to assert that the controller →
    job → moderation → client wire shape carries the rejection list.
    """
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("analyze", payload) do
      case :persistent_term.get({Stacks.ModerationTest, :capture_pid}, nil) do
        nil -> :ok
        pid -> send(pid, {:vision_payload, payload})
      end

      {:ok,
       %{
         "classification" => "CLASSIFICATION_RESULT_BOOK",
         "confidence" => 0.95,
         "books" => [],
         "model_used" => "mock"
       }}
    end

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule SingleIsbnCandidateClient do
    @moduledoc """
    Single candidate with a known checksum-valid ISBN — used by the
    excluded_isbns drop-candidate test. When the ISBN matches an entry in
    `excluded_isbns`, the candidate is dropped before resolve_and_store
    runs and the pipeline reports isbn_not_found.
    """
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("analyze", _payload) do
      {:ok,
       %{
         "classification" => "CLASSIFICATION_RESULT_BOOK",
         "confidence" => 0.95,
         "books" => [
           %{
             "title" => nil,
             "author" => nil,
             "potential_isbns" => ["9780743273565"],
             "raw_text" => nil,
             "confidence" => 0.9
           }
         ],
         "model_used" => "mock"
       }}
    end

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule NullAuthorClient do
    @moduledoc """
    Reproduces the production VLM payload that surfaced the null-author
    and scrystal bugs: author is the literal string "null" and the
    raw_text contains a possessive apostrophe.
    """
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("analyze", _payload) do
      {:ok,
       %{
         "classification" => "CLASSIFICATION_RESULT_BOOK",
         "confidence" => 0.9,
         "books" => [
           %{
             "title" => "The Tramp's Crystal City",
             "author" => "null",
             "potential_isbns" => [],
             "raw_text" => "THE TRAMP'S CRYSTAL CITY",
             "confidence" => 0.9
           }
         ],
         "model_used" => "mock"
       }}
    end

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule LowConfidenceNoIsbnClient do
    @moduledoc """
    Low-confidence candidate (below #167 threshold 0.5) with no
    potential_isbns — exercises nil ISBN telemetry metadata on the
    #167 skip path.
    """
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("analyze", _payload) do
      {:ok,
       %{
         "classification" => "CLASSIFICATION_RESULT_BOOK",
         "confidence" => 0.95,
         "books" => [
           %{
             "title" => "Some Title",
             "author" => nil,
             "potential_isbns" => [],
             "raw_text" => nil,
             "confidence" => 0.4
           }
         ],
         "model_used" => "mock"
       }}
    end

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end
end
