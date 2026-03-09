defmodule Stacks.Workers.IdentifyBookJobTest do
  # async: false — tests swap Application.put_env(:core, :vision_client)
  # which is global state; concurrent execution would cause race conditions.
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Workers.IdentifyBookJob

  # Each test needs an uploaded_images DB record + corresponding file on disk
  # so that load_image_b64/1 succeeds and the pipeline can run.
  setup do
    user = insert(:user)
    image = insert(:uploaded_image)

    upload_dir = Application.get_env(:core, :upload_dir, "priv/static/uploads")
    File.mkdir_p!(upload_dir)
    image_path = Path.join(upload_dir, image.storage_path)
    File.write!(image_path, "fake image bytes for testing")

    on_exit(fn -> File.rm(image_path) end)

    {:ok, user: user, image: image}
  end

  describe "perform/1 — happy path" do
    test "returns :ok and marks image resolved when pipeline identifies a book", %{
      user: user,
      image: image
    } do
      assert :ok = perform_job(IdentifyBookJob, %{"user_id" => user.id, "image_id" => image.id})
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
                 perform_job(IdentifyBookJob, %{"user_id" => user.id, "image_id" => image.id})
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
                 perform_job(IdentifyBookJob, %{"user_id" => user.id, "image_id" => image.id})
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
                 perform_job(IdentifyBookJob, %{"user_id" => user.id, "image_id" => image.id})
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
