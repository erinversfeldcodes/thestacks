defmodule Stacks.ModerationTest do
  @moduledoc """
  Tests for Stacks.Moderation pipeline.

  The vision client is configured to Stacks.AI.MockClient in test.exs, so all
  calls to AIClient.call_vision/2 use the mock without hitting the network.

  classify_subjects calls Books.resolve_isbn, which would make real HTTP calls
  to Open Library. The moderation code already handles that failure gracefully
  by returning {:ok, %{subjects: [], bisac_codes: []}} when resolve_isbn fails,
  so no HTTP mocking is needed.
  """

  # async: false — tests use Application.put_env to swap the vision client,
  # which is global process state and not safe for concurrent test execution.
  use Core.DataCase, async: false

  import Stacks.Factory

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

      assert {:ok, [book]} = Moderation.run_pipeline(context)
      assert [edition | _] = book.editions
      assert edition.isbn == "9780743273565"
      assert book.visibility_tier in ["public", "age_gated"]
    end

    test "stores book with public tier when no adult BISAC codes are present" do
      context = %{
        image_b64: @test_image_b64,
        book_attrs: %{"title" => "A Peaceful Novel"}
      }

      assert {:ok, [book]} = Moderation.run_pipeline(context)
      assert book.visibility_tier == "public"
    end

    test "stores book with age_gated visibility_tier when adult BISAC code present" do
      age_gated_book = insert(:book, visibility_tier: "age_gated")
      insert(:book_edition, book: age_gated_book, isbn: "9780385490818")

      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.AdultBisacClient)

        context = %{image_b64: @test_image_b64}
        assert {:ok, [book]} = Moderation.run_pipeline(context)
        assert book.visibility_tier == "age_gated"
      after
        Application.put_env(:core, :vision_client, original)
      end
    end

    test "returns existing book when ISBN already in database" do
      existing = insert(:book)
      insert(:book_edition, book: existing, isbn: "9780743273565")

      context = %{
        image_b64: @test_image_b64,
        book_attrs: %{"title" => "Should Not Matter"}
      }

      assert {:ok, [book]} = Moderation.run_pipeline(context)
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
        assert {:ok, books} = Moderation.run_pipeline(context)
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

  # ---------------------------------------------------------------------------
  # Inline mock modules for specific failure scenarios
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Inline mock modules for specific failure scenarios. Each returns the
  # consolidated /analyze shape (classification + books in one response).
  # ---------------------------------------------------------------------------

  defmodule AdultBisacClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("analyze", _payload),
      do:
        {:ok,
         %{
           "classification" => "CLASSIFICATION_RESULT_BOOK",
           "confidence" => 0.9,
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
end
