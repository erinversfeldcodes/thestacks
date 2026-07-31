defmodule Stacks.Workers.IdentifyBookJobTest do
  # async: false — Core.DataCase's sandbox mode. Vision steering itself is
  # process-local (Stacks.AI.MockClient), so it is not what serialises this
  # file; the ISBN resolver's :fuse state and Stacks.Books.MockHttpClient are.
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.AI.VisionFixtures
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Books.MockHttpClient
  alias Stacks.Books.UploadedImage
  alias Stacks.Workers.IdentifyBookJob

  @image_b64 Base.encode64("fake image bytes for testing")

  setup do
    user = insert(:user)
    image = insert(:uploaded_image)
    # Pre-insert the book the MockVisionClient returns so store_book finds it via
    # Books.find_existing/1 without needing to resolve metadata over HTTP.
    book = insert(:book)
    insert(:book_edition, book: book, isbn: "9780743273565")
    {:ok, user: user, image: image, book: book}
  end

  describe "perform/1 — happy path" do
    test "returns :ok and marks image resolved when pipeline identifies a book", %{
      user: user,
      image: image
    } do
      assert :ok =
               perform_job(IdentifyBookJob, %{
                 "user_id" => user.id,
                 "image_id" => image.id,
                 "image_b64" => @image_b64
               })

      updated = Repo.get!(UploadedImage, image.id)
      assert updated.status == "resolved"
      assert updated.book_ids != []
    end

    test "emits image.resolved event", %{user: user, image: image} do
      before_count = event_count("image.resolved")

      perform_job(IdentifyBookJob, %{
        "user_id" => user.id,
        "image_id" => image.id,
        "image_b64" => @image_b64
      })

      assert event_count("image.resolved") == before_count + 1
    end
  end

  describe "perform/1 — multi-book path" do
    test "marks image resolved with all book_ids when pipeline returns multiple books", %{
      user: user,
      image: image,
      book: book
    } do
      book2 = insert(:book)
      insert(:book_edition, book: book2, isbn: "9780385333481")

      with_vision(multi_book(), fn ->
        assert :ok =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })

        resolved = Repo.get!(Stacks.Books.UploadedImage, image.id)
        assert resolved.status == "resolved"
        assert book.id in resolved.book_ids
        assert book2.id in resolved.book_ids
        assert length(resolved.book_ids) == 2
      end)
    end
  end

  describe "perform/1 — multi-book zero-resolve path" do
    test "returns {:cancel, isbn_not_found} when multi-book pipeline resolves zero books", %{
      user: user,
      image: image
    } do
      with_vision(multi_book_no_resolve(), fn ->
        assert {:cancel, "isbn_not_found"} =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })
      end)
    end
  end

  describe "perform/1 — multi-book partial-resolve path" do
    test "returns :ok with one book when only 1 of 2 ISBNs resolves", %{
      user: user,
      image: image,
      book: book
    } do
      with_vision(multi_book_partial(), fn ->
        assert :ok =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })

        resolved = Repo.get!(Stacks.Books.UploadedImage, image.id)
        assert resolved.status == "resolved"
        assert resolved.book_ids == [book.id]
        assert length(resolved.book_ids) == 1
      end)
    end

    test "emits image.resolved plus one image.rejected per failed ISBN, all tied to the same image_id",
         %{user: user, image: image, book: book} do
      resolved_before = event_count("image.resolved")
      rejected_before = event_count("image.rejected")

      with_vision(multi_book_partial(), fn ->
        assert :ok =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })
      end)

      # Exactly one image.resolved (the upload succeeded overall) and one
      # image.rejected per failed candidate (the MultiBookPartialClient
      # supplies 2 candidates, only the 9780743273565 one resolves).
      assert event_count("image.resolved") == resolved_before + 1
      assert event_count("image.rejected") == rejected_before + 1

      events = events_of_type("image.rejected")
      latest = List.last(events)

      # The rejection ties back to the upload via aggregate_id, NOT to a
      # book row that was never created. Downstream observability tooling
      # groups by image aggregate to reconstruct the partial outcome.
      assert latest.aggregate_id == image.id
      assert latest.aggregate_type == "image"
      assert latest.payload["isbn"] == "9780000000003"
      assert latest.payload["reason"] != nil

      # Sanity: the resolved book row was still persisted via mark_resolved.
      resolved = Repo.get!(Stacks.Books.UploadedImage, image.id)
      assert resolved.status == "resolved"
      assert resolved.book_ids == [book.id]
    end
  end

  describe "perform/1 — storage_path preservation" do
    @tag stories: ["US-1.1.2", "US-1.1.3"], suite: :storage
    test "storage_path is preserved when image is rejected", %{user: user} do
      image =
        insert(:uploaded_image,
          storage_path: "uploads/test-#{System.unique_integer([:positive])}.jpg"
        )

      with_vision(not_a_book(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      end)

      updated = Repo.get!(UploadedImage, image.id)
      assert updated.status == "rejected"
      assert updated.storage_path == image.storage_path
    end
  end

  describe "perform/1 — default public tier (classifier removed)" do
    @tag stories: ["US-1.1.4"], suite: :jobs
    test "pipeline creates a public book even for subjects that previously gated", %{user: user} do
      # The automatic subject→BISAC age-gate classifier was removed: a freshly
      # identified book enters `public` regardless of its subjects. Age-gating
      # now happens only when a PERSON marks the book (Books.set_visibility_tier/3).
      # "romance" used to force the age_gated branch.
      :fuse.reset(:open_library_fuse)
      :fuse.reset(:google_books_fuse)

      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:9780385490818" => %{
             "title" => "Formerly Gated Romance",
             "subjects" => ["romance"]
           }
         }}
      )

      image = insert(:uploaded_image)

      with_vision(age_gated_book(), fn ->
        assert :ok =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })
      end)

      updated_image = Repo.get!(UploadedImage, image.id)
      assert updated_image.status == "resolved"
      book = Repo.get!(Stacks.Books.Book, hd(updated_image.book_ids))
      assert book.visibility_tier == "public"
    end
  end

  describe "perform/1 — not_a_book path" do
    test "returns {:cancel, reason} when vision model says image is not a book", %{
      user: user,
      image: image
    } do
      with_vision(not_a_book(), fn ->
        assert {:cancel, "image does not contain a book"} =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })
      end)
    end

    test "emits image.rejected event", %{user: user, image: image} do
      before_count = event_count("image.rejected")

      with_vision(not_a_book(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      end)

      assert event_count("image.rejected") == before_count + 1
    end
  end

  describe "perform/1 — isbn_not_found path" do
    test "returns {:cancel, reason} when vision model cannot extract an ISBN", %{
      user: user,
      image: image
    } do
      with_vision(no_isbn(), fn ->
        assert {:cancel, "isbn_not_found"} =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })
      end)
    end
  end

  describe "perform/1 — generic pipeline failure" do
    test "returns {:error, reason} when pipeline fails with an unexpected error", %{
      user: user,
      image: image
    } do
      # `:any` — the old ErrorClient failed every endpoint, not just /analyze.
      with_vision(:any, service_error(), fn ->
        assert {:error, :service_unavailable} =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })
      end)
    end
  end

  describe "perform/1 — excluded_books arg" do
    # Rejection-retry: when the controller enqueues a fresh job after
    # the user clicked "No, try again", the cumulative excluded_books
    # list rides on the Oban args and must be forwarded to
    # Moderation.run_pipeline via the context, which forwards it to
    # the vision sidecar as part of the /analyze payload.

    test "passes excluded_books from job args into the vision payload", %{
      user: user,
      image: image
    } do
      with_vision(capture_payload(self()), fn ->
        _ =
          perform_job(IdentifyBookJob, %{
            "user_id" => user.id,
            "image_id" => image.id,
            "image_b64" => @image_b64,
            "excluded_books" => ["The Great Gatsby by F. Scott Fitzgerald"]
          })

        assert_receive {:vision_payload, payload}, 1_000
        assert payload[:excluded_books] == ["The Great Gatsby by F. Scott Fitzgerald"]
      end)
    end

    test "forwards excluded_isbns from job args into the moderation context" do
      # Rejection-retry: excluded_isbns is consumed by the resolver (not
      # the vision sidecar), so we assert behaviour via a single direct-
      # ISBN candidate matching an excluded entry — the candidate is
      # dropped before resolve_and_store runs, yielding isbn_not_found.
      user = insert(:user)
      image = insert(:uploaded_image, user_id: user.id)

      with_vision(single_isbn_excludable(), fn ->
        assert {:cancel, "isbn_not_found"} =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64,
                   "excluded_isbns" => ["9780743273565"]
                 })
      end)
    end

    test "omits excluded_books from payload when arg is missing", %{user: user, image: image} do
      with_vision(capture_payload(self()), fn ->
        _ =
          perform_job(IdentifyBookJob, %{
            "user_id" => user.id,
            "image_id" => image.id,
            "image_b64" => @image_b64
          })

        assert_receive {:vision_payload, payload}, 1_000
        refute Map.has_key?(payload, :excluded_books)
      end)
    end
  end

  describe "perform/1 — image not in DB" do
    test "returns :ok and logs warning when resolved image_id does not exist in DB", %{user: user} do
      # mark_resolved finds no rows → logs "not found" but still returns :ok
      assert :ok =
               perform_job(IdentifyBookJob, %{
                 "user_id" => user.id,
                 "image_id" => Ecto.UUID.generate(),
                 "image_b64" => @image_b64
               })
    end

    test "returns {:cancel, reason} and logs warning when rejected image_id does not exist", %{
      user: user
    } do
      with_vision(not_a_book(), fn ->
        assert {:cancel, "image does not contain a book"} =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => Ecto.UUID.generate(),
                   "image_b64" => @image_b64
                 })
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp event_count(event_type) do
    Repo.aggregate(
      from(e in "event_log", prefix: "op", where: e.event_type == ^event_type),
      :count
    )
  end

  # Mirrors the helper in upload_pipeline_test.exs — the raw event_log query
  # returns aggregate_id as binary; we decode to a string UUID so callers
  # can compare against the original UUID without juggling encodings.
  defp events_of_type(event_type) do
    from(e in "event_log",
      prefix: "op",
      where: e.event_type == ^event_type,
      order_by: [asc: e.occurred_at],
      select: %{
        event_type: e.event_type,
        aggregate_type: e.aggregate_type,
        aggregate_id: e.aggregate_id,
        payload: e.payload,
        occurred_at: e.occurred_at
      }
    )
    |> Repo.all()
    |> Enum.map(fn event ->
      decoded_id =
        case Ecto.UUID.load(event.aggregate_id) do
          {:ok, str} -> str
          _ -> event.aggregate_id
        end

      %{event | aggregate_id: decoded_id}
    end)
  end

  # ---------------------------------------------------------------------------
  # Vision scenarios
  # ---------------------------------------------------------------------------
  #
  # Each is a response the real seam (Stacks.AI.MockClient) is steered with —
  # no bespoke replacement client modules. All use the consolidated /analyze
  # shape (classification + books in one response), which is what the
  # post-consolidation Moderation pipeline calls.

  defp age_gated_book, do: books_with_isbns(["9780385490818"])

  defp multi_book,
    do: books_with_isbns(["9780743273565", "9780385333481"], confidence: 0.95)

  defp multi_book_no_resolve,
    do: books_with_isbns(["9780000000001", "9780000000002"], confidence: 0.95)

  # One resolvable candidate (pre-inserted in setup) plus one that no lookup
  # can satisfy — the partial-resolve branch.
  defp multi_book_partial,
    do: books_with_isbns(["9780743273565", "9780000000003"], confidence: 0.95)

  # One direct-ISBN candidate — used by the `excluded_isbns` arg test to verify
  # that the args → context → drop-candidate plumbing works end-to-end through
  # the worker.
  defp single_isbn_excludable, do: books_with_isbns(["9780743273565"], confidence: 0.95)
end
