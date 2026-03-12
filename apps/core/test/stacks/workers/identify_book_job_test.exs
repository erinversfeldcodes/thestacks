defmodule Stacks.Workers.IdentifyBookJobTest do
  # async: false — tests swap Application.put_env(:core, :vision_client)
  # which is global state; concurrent execution would cause race conditions.
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Workers.IdentifyBookJob

  @image_b64 Base.encode64("fake image bytes for testing")

  setup do
    user = insert(:user)
    image = insert(:uploaded_image)
    # Pre-insert the book the MockVisionClient returns so store_book finds it via
    # Books.find_existing/1 without needing to resolve metadata over HTTP.
    book = insert(:book, isbn: "9780743273565")
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
  # Inline mock modules
  # ---------------------------------------------------------------------------

  defmodule NotABookClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour
    @impl true
    def call_vision("is_book", _payload),
      do: {:ok, %{"classification" => "not_book", "confidence" => 0.95, "model_used" => "mock"}}

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule NoIsbnClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour
    @impl true
    def call_vision("is_book", _payload),
      do: {:ok, %{"classification" => "book", "confidence" => 0.9, "model_used" => "mock"}}

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
end
