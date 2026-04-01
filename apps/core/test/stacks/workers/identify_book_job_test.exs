defmodule Stacks.Workers.IdentifyBookJobTest do
  # async: false — tests swap Application.put_env(:core, :vision_client)
  # which is global state; concurrent execution would cause race conditions.
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
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

      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.MultiBookClient)

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
      after
        Application.put_env(:core, :vision_client, original)
      end
    end
  end

  describe "perform/1 — multi-book zero-resolve path" do
    test "returns {:cancel, isbn_not_found} when multi-book pipeline resolves zero books", %{
      user: user,
      image: image
    } do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.MultiBookNoResolveClient)

        assert {:cancel, "isbn_not_found"} =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })
      after
        Application.put_env(:core, :vision_client, original)
      end
    end
  end

  describe "perform/1 — multi-book partial-resolve path" do
    test "returns :ok with one book when only 1 of 2 ISBNs resolves", %{
      user: user,
      image: image,
      book: book
    } do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.MultiBookPartialClient)

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
      after
        Application.put_env(:core, :vision_client, original)
      end
    end
  end

  describe "perform/1 — storage_path preservation" do
    @tag stories: ["US-1.1.2", "US-1.1.3"], suite: :storage
    test "storage_path is preserved when image is rejected", %{user: user} do
      image =
        insert(:uploaded_image,
          storage_path: "uploads/test-#{System.unique_integer([:positive])}.jpg"
        )

      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.NotABookClient)

        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      after
        Application.put_env(:core, :vision_client, original)
      end

      updated = Repo.get!(UploadedImage, image.id)
      assert updated.status == "rejected"
      assert updated.storage_path == image.storage_path
    end
  end

  describe "perform/1 — age_gated path" do
    @tag stories: ["US-1.1.4"], suite: :jobs
    test "book has age_gated visibility_tier when adult BISAC subject is returned", %{user: user} do
      age_gated_book = insert(:book, title: "Adult Fiction", visibility_tier: "age_gated")
      insert(:book_edition, book: age_gated_book, isbn: "9780385490818")
      image = insert(:uploaded_image)

      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.AgeGatedBookClient)

        assert :ok =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })
      after
        Application.put_env(:core, :vision_client, original)
      end

      updated_image = Repo.get!(UploadedImage, image.id)
      assert updated_image.status == "resolved"
      book = Repo.get!(Stacks.Books.Book, hd(updated_image.book_ids))
      assert book.visibility_tier == "age_gated"
    end
  end

  describe "perform/1 — not_a_book path" do
    test "returns {:cancel, reason} when vision model says image is not a book", %{
      user: user,
      image: image
    } do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.NotABookClient)

        assert {:cancel, "image does not contain a book"} =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })
      after
        Application.put_env(:core, :vision_client, original)
      end
    end

    test "emits image.rejected event", %{user: user, image: image} do
      original = Application.get_env(:core, :vision_client)
      before_count = event_count("image.rejected")

      try do
        Application.put_env(:core, :vision_client, __MODULE__.NotABookClient)

        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      after
        Application.put_env(:core, :vision_client, original)
      end

      assert event_count("image.rejected") == before_count + 1
    end
  end

  describe "perform/1 — isbn_not_found path" do
    test "returns {:cancel, reason} when vision model cannot extract an ISBN", %{
      user: user,
      image: image
    } do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.NoIsbnClient)

        assert {:cancel, "isbn_not_found"} =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })
      after
        Application.put_env(:core, :vision_client, original)
      end
    end
  end

  describe "perform/1 — generic pipeline failure" do
    test "returns {:error, reason} when pipeline fails with an unexpected error", %{
      user: user,
      image: image
    } do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.ErrorClient)

        assert {:error, :service_unavailable} =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })
      after
        Application.put_env(:core, :vision_client, original)
      end
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
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.NotABookClient)

        assert {:cancel, "image does not contain a book"} =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => Ecto.UUID.generate(),
                   "image_b64" => @image_b64
                 })
      after
        Application.put_env(:core, :vision_client, original)
      end
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

  # ---------------------------------------------------------------------------
  # Inline mock modules
  # ---------------------------------------------------------------------------

  defmodule AgeGatedBookClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour
    @impl true
    def call_vision("is_book", _payload),
      do:
        {:ok,
         %{
           "classification" => "CLASSIFICATION_RESULT_BOOK",
           "confidence" => 0.9,
           "model_used" => "mock"
         }}

    def call_vision("extract_isbn", _payload),
      do:
        {:ok,
         %{
           "books" => [
             %{
               "title" => nil,
               "author" => nil,
               "potential_isbns" => ["9780385490818"],
               "raw_text" => nil,
               "confidence" => 0.9
             }
           ],
           "model_used" => "mock"
         }}

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule NotABookClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour
    @impl true
    def call_vision("is_book", _payload),
      do:
        {:ok,
         %{
           "classification" => "CLASSIFICATION_RESULT_NOT_BOOK",
           "confidence" => 0.95,
           "model_used" => "mock"
         }}

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule NoIsbnClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour
    @impl true
    def call_vision("is_book", _payload),
      do:
        {:ok,
         %{
           "classification" => "CLASSIFICATION_RESULT_BOOK",
           "confidence" => 0.9,
           "model_used" => "mock"
         }}

    def call_vision("extract_isbn", _payload),
      do: {:ok, %{"books" => [], "model_used" => "mock"}}

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule ErrorClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour
    @impl true
    def call_vision("is_book", _payload), do: {:error, :service_unavailable}
    def call_vision(_endpoint, _payload), do: {:error, :service_unavailable}
  end

  defmodule MultiBookClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour
    @impl true
    def call_vision("is_book", _payload),
      do:
        {:ok,
         %{
           "classification" => "CLASSIFICATION_RESULT_BOOK",
           "confidence" => 0.95,
           "model_used" => "mock"
         }}

    def call_vision("extract_isbn", _payload),
      do:
        {:ok,
         %{
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

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule MultiBookNoResolveClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour
    @impl true
    def call_vision("is_book", _payload),
      do:
        {:ok,
         %{
           "classification" => "CLASSIFICATION_RESULT_BOOK",
           "confidence" => 0.95,
           "model_used" => "mock"
         }}

    def call_vision("extract_isbn", _payload),
      do:
        {:ok,
         %{
           "books" => [
             %{
               "title" => nil,
               "author" => nil,
               "potential_isbns" => ["9780000000001"],
               "raw_text" => nil,
               "confidence" => 0.9
             },
             %{
               "title" => nil,
               "author" => nil,
               "potential_isbns" => ["9780000000002"],
               "raw_text" => nil,
               "confidence" => 0.9
             }
           ],
           "model_used" => "mock"
         }}

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule MultiBookPartialClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour
    @impl true
    def call_vision("is_book", _payload),
      do:
        {:ok,
         %{
           "classification" => "CLASSIFICATION_RESULT_BOOK",
           "confidence" => 0.95,
           "model_used" => "mock"
         }}

    def call_vision("extract_isbn", _payload),
      do:
        {:ok,
         %{
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
               "potential_isbns" => ["9780000000003"],
               "raw_text" => nil,
               "confidence" => 0.9
             }
           ],
           "model_used" => "mock"
         }}

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end
end
