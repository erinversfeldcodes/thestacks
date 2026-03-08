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

  # The MockClient default for "extract_isbn" returns "9780743273565" when no
  # :isbn key is present in the payload. The "is_book" call always returns true.

  describe "run_pipeline/1 — happy path" do
    test "returns {:ok, book} when vision model confirms it is a book with valid ISBN" do
      # The mock client returns is_book: true and isbn: "9780743273565".
      # classify_subjects falls back to empty subjects when Open Library is unreachable.
      # store_with_tier finds no existing book and creates one.
      context = %{
        image_url: "https://example.com/book.jpg",
        book_attrs: %{"title" => "The Great Gatsby"}
      }

      assert {:ok, book} = Moderation.run_pipeline(context)
      assert book.isbn == "9780743273565"
      assert book.visibility_tier in ["public", "age_gated"]
    end

    test "stores book with public tier when no adult BISAC codes are present" do
      # With empty bisac_codes (Open Library unreachable fallback), tier is "public"
      context = %{
        image_url: "https://example.com/book.jpg",
        book_attrs: %{"title" => "A Peaceful Novel"}
      }

      assert {:ok, book} = Moderation.run_pipeline(context)
      assert book.visibility_tier == "public"
    end

    test "returns existing book when ISBN already in database" do
      existing = insert(:book, isbn: "9780743273565")

      context = %{
        image_url: "https://example.com/book.jpg",
        book_attrs: %{"title" => "Should Not Matter"}
      }

      assert {:ok, book} = Moderation.run_pipeline(context)
      assert book.id == existing.id
    end
  end

  describe "run_pipeline/1 — not_a_book path" do
    test "returns {:error, :not_a_book} when vision model says it is not a book" do
      # Override the vision client for this test by temporarily swapping
      # to a custom mock. We use Application.put_env within the test process.
      # Since the default MockClient always returns is_book: true, we define
      # a test-local module that returns is_book: false.
      #
      # The cleanest approach without Mox: wrap in a process that overrides
      # Application env temporarily.
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.NotABookClient)

        context = %{image_url: "https://example.com/not_a_book.jpg"}
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

        context = %{image_url: "https://example.com/book.jpg"}
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(context)
      after
        Application.put_env(:core, :vision_client, original)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Inline mock modules for specific failure scenarios
  # ---------------------------------------------------------------------------

  defmodule NotABookClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("is_book", _payload), do: {:ok, %{"is_book" => false}}
    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule NoIsbnClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour

    @impl true
    def call_vision("is_book", _payload), do: {:ok, %{"is_book" => true}}
    # Returns response without an "isbn" key — triggers :isbn_not_found
    def call_vision("extract_isbn", _payload), do: {:ok, %{"isbn" => ""}}
    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end
end
