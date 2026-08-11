defmodule Stacks.ModerationTest do
  @moduledoc """
  Tests for Stacks.Moderation pipeline.

  The vision client is configured to Stacks.AI.MockClient in test.exs, so all
  calls to AIClient.call_vision/2 use the mock without hitting the network.

  ISBN resolution (Books.resolve_isbn) would otherwise make real HTTP calls to
  Open Library; the pipeline handles a resolution failure gracefully (empty
  subjects/bisac_codes), so no HTTP mocking is needed here.
  """

  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.AI.VisionFixtures
  import Stacks.Factory

  alias Stacks.Books.ISBNResolver
  alias Stacks.Books.MockHttpClient
  alias Stacks.Moderation

  @test_image_b64 Base.encode64("fake image bytes")

  setup do
    :fuse.reset(:open_library_fuse)
    :fuse.reset(:google_books_fuse)
    :ok
  end

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

  describe "run_pipeline/1 — the resolver's cross-reference ids reach the row (#346)" do
    test "an Open Library hit stores open_library_id, and the provenance agrees" do
      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:9780743273565" => %{
             "title" => "The Great Gatsby",
             "authors" => [%{"name" => "F. Scott Fitzgerald"}],
             "key" => "/books/OL7353617M"
           }
         }}
      )

      assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(%{image_b64: @test_image_b64})
      edition = hd(book.editions)

      assert edition.open_library_id == "/books/OL7353617M",
             "the upload path dropped the Open Library id it had just been handed"

      assert edition.verification_source == "open_library",
             "provenance must be derived from the id on the row, not asserted beside it"
    end

    test "a Google Books hit stores google_books_id, and the provenance agrees" do
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})

      MockHttpClient.put_response(
        "googleapis.com",
        {:ok,
         %{
           "items" => [
             %{
               "id" => "gb-gatsby",
               "volumeInfo" => %{
                 "title" => "The Great Gatsby",
                 "authors" => ["F. Scott Fitzgerald"]
               }
             }
           ]
         }}
      )

      assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(%{image_b64: @test_image_b64})
      edition = hd(book.editions)

      assert edition.google_books_id == "gb-gatsby",
             "the upload path dropped the Google Books id it had just been handed"

      assert is_nil(edition.open_library_id),
             "Open Library did not answer — it must not be credited with one"

      assert edition.verification_source == "google_books"
    end

    test "the barcode fast path still records that nothing external confirmed it" do
      with_vision(local_ocr(), fn ->
        assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(%{image_b64: @test_image_b64})
        edition = hd(book.editions)

        assert is_nil(edition.open_library_id) and is_nil(edition.google_books_id),
               "the fast path resolves no metadata, so it has no id to claim"

        assert edition.verification_source == "barcode_unverified"
      end)
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
        context = %{
          image_b64: @test_image_b64,
          book_attrs: %{"title" => "High Confidence Book"}
        }

        assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(context)
        assert [edition | _] = book.editions
        assert edition.isbn == "9780743273565"

        refute_receive {:telemetry_event, [:stacks, :enrichment, :candidate, :skipped], _, _},
                       100
      end)
    end

    test "low-confidence candidate (< threshold) is skipped and emits telemetry" do
      with_vision(low_confidence(), fn ->
        context = %{image_b64: @test_image_b64}
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)

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
    test "VLM candidate whose direct ISBN matches an excluded entry is dropped" do
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
    test "candidate with author=\"null\" reaches search_by_title with author=nil" do
      with_vision(null_author(), fn ->
        MockHttpClient.capture_requests()

        context = %{image_b64: @test_image_b64}
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)

        urls = collect_request_urls()
        assert urls != [], "expected the title-search to issue HTTP requests"

        refute Enum.any?(urls, &String.contains?(&1, "inauthor"))
        refute Enum.any?(urls, &String.contains?(&1, "null"))

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
    test "creates a placeholder book and enqueues EnrichBookJob when source is local_ocr" do
      with_vision(local_ocr(), fn ->
        context = %{image_b64: @test_image_b64}
        assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(context)
        assert String.starts_with?(book.title, "ISBN ")

        edition = List.first(book.editions)
        assert_enqueued(worker: Stacks.Workers.EnrichBookJob, args: %{"isbn" => edition.isbn})

        assert edition.verification_source == "barcode_unverified"
      end)
    end

    test "the placeholder title stops being the only record of an unverified ISBN" do
      with_vision(local_ocr(), fn ->
        assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(%{image_b64: @test_image_b64})
        edition = List.first(book.editions)

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
      with_vision(vlm_extracted_isbn(), fn ->
        context = %{image_b64: @test_image_b64}
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)

        refute_enqueued(worker: Stacks.Workers.EnrichBookJob)
      end)
    end
  end

  describe "run_pipeline/1 — a resolver outage is not the book's fault (#344)" do
    setup do
      MockHttpClient.put_response("openlibrary.org/api/books", {:error, :unexpected_status})
      MockHttpClient.put_response("googleapis.com", {:error, :unexpected_status})
      :ok
    end

    test "a candidate whose lookup 5xx'd is recorded as :resolver_unavailable, never :invalid_book" do
      existing = insert(:book)
      insert(:book_edition, book: existing, isbn: "9780743273565")

      with_vision(books_with_isbns(["9780743273565", "9780385333481"]), fn ->
        assert {:ok, %{resolved: [resolved], rejected: rejected}} =
                 Moderation.run_pipeline(%{image_b64: @test_image_b64})

        assert resolved.id == existing.id

        assert [{"9780385333481", reason}] = rejected

        refute reason == :invalid_book,
               "a 5xx from Google Books is not evidence that the reader photographed a non-book"

        assert reason == :resolver_unavailable
      end)
    end

    test "the funnel counter names the outage rather than coercing it to :other" do
      test_pid = self()
      handler_id = "test-344-funnel-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:stacks, :moderation, :isbn_resolution],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:resolution_outcome, metadata.outcome})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      with_vision(books_with_isbns(["9780743273565"]), fn ->
        assert {:error, :resolver_unavailable} =
                 Moderation.run_pipeline(%{image_b64: @test_image_b64})
      end)

      assert_receive {:resolution_outcome, :resolver_unavailable}
    end

    test "the whole-image failure is retryable, not a terminal 'no ISBN in this photo'" do
      with_vision(books_with_isbns(["9780743273565"]), fn ->
        assert {:error, :resolver_unavailable} =
                 Moderation.run_pipeline(%{image_b64: @test_image_b64})
      end)
    end

    test "a book we already hold is still resolved while the resolver is down" do
      existing = insert(:book)
      insert(:book_edition, book: existing, isbn: "9780743273565")

      with_vision(books_with_isbns(["9780743273565"]), fn ->
        assert {:ok, %{resolved: [book], rejected: []}} =
                 Moderation.run_pipeline(%{image_b64: @test_image_b64})

        assert book.id == existing.id
      end)
    end

    test "an ISBN both catalogues have HEARD of and denied is still :invalid_book" do
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      existing = insert(:book)
      insert(:book_edition, book: existing, isbn: "9780743273565")

      with_vision(books_with_isbns(["9780743273565", "9780385333481"]), fn ->
        assert {:ok, %{rejected: [{"9780385333481", :invalid_book}]}} =
                 Moderation.run_pipeline(%{image_b64: @test_image_b64})
      end)
    end
  end

  describe "title_fallback/5's closed failure set (#344, #352)" do
    test "every reachable failure maps to :not_found or :unavailable, and nothing else" do
      unavailable = [
        {:error, :unexpected_status},
        {:error, :malformed_response},
        {:error, :transport_error},
        {:error, :timeout}
      ]

      not_found = [
        {:ok, %{}},
        {:ok, %{"docs" => []}}
      ]

      for {failure, expected} <-
            Enum.map(unavailable, &{&1, :unavailable}) ++
              Enum.map(not_found, &{&1, :not_found}) do
        :fuse.reset(:open_library_fuse)
        :fuse.reset(:google_books_fuse)
        MockHttpClient.clear()
        MockHttpClient.put_response("openlibrary.org", failure)
        MockHttpClient.put_response("googleapis.com", failure)

        assert {:error, ^expected} = ISBNResolver.search_by_title("A Title", "An Author", nil),
               "search_by_title/4 no longer maps #{inspect(failure)} to #{inspect(expected)} — " <>
                 "check Moderation.title_fallback/5 still has a clause for what it returns now"
      end
    end
  end

  describe "run_pipeline/1 — a title-search outage is not the book's fault (#352)" do
    test "both catalogues unreachable rejects as :resolver_unavailable, not :isbn_not_found" do
      MockHttpClient.put_response("openlibrary.org", {:error, :transport_error})
      MockHttpClient.put_response("googleapis.com", {:error, :transport_error})

      with_vision(null_author(), fn ->
        assert {:error, :resolver_unavailable} =
                 Moderation.run_pipeline(%{image_b64: @test_image_b64})
      end)
    end

    test "both catalogues answering with no results still rejects as :isbn_not_found" do
      MockHttpClient.put_response("openlibrary.org", {:ok, %{"docs" => []}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => []}})

      with_vision(null_author(), fn ->
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(%{image_b64: @test_image_b64})
      end)
    end
  end

  @gatsby "9780743273565"

  defp local_ocr,
    do:
      books_with_isbns([@gatsby],
        confidence: 1.0,
        candidate_confidence: 1.0,
        model_used: "local_ocr"
      )

  defp vlm_extracted_isbn,
    do:
      books_with_isbns([@gatsby],
        confidence: 0.85,
        candidate_confidence: 0.8,
        model_used: "Qwen/Qwen2.5-VL-7B-Instruct"
      )

  defp compound_title, do: books_with_isbns([@gatsby, "9780385333481"])

  defp no_resolvable, do: book_response([book_candidate()])

  defp empty_title, do: book_response([book_candidate(title: "")])

  defp high_confidence, do: books_with_isbns([@gatsby], confidence: 0.95)

  defp low_confidence,
    do: books_with_isbns([@gatsby], confidence: 0.95, candidate_confidence: 0.4)

  defp mid_confidence,
    do: books_with_isbns([@gatsby], confidence: 0.95, candidate_confidence: 0.7)

  defp no_confidence,
    do: book_response([book_candidate(potential_isbns: [@gatsby])], confidence: 0.95)

  defp nil_confidence,
    do: books_with_isbns([@gatsby], confidence: 0.95, candidate_confidence: nil)

  defp low_confidence_no_isbn do
    book_response([book_candidate(title: "Some Title", confidence: 0.4)], confidence: 0.95)
  end

  defp single_isbn_candidate, do: books_with_isbns([@gatsby], confidence: 0.95)

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
