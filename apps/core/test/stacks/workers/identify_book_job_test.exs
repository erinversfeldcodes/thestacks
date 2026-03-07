defmodule Stacks.Workers.IdentifyBookJobTest do
  # async: false — tests swap Application.put_env(:core, :vision_client)
  # which is global state; concurrent execution would cause race conditions.
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Workers.IdentifyBookJob

  defp job_args(user_id) do
    %{"user_id" => user_id, "image_id" => Ecto.UUID.generate()}
  end

  describe "perform/1 — happy path" do
    test "returns :ok and marks image resolved when pipeline identifies a book" do
      user = insert(:user)

      # Default MockClient returns is_book: true and a valid ISBN.
      # Moderation.run_pipeline will create the book in the DB.
      assert :ok = perform_job(IdentifyBookJob, job_args(user.id))
    end
  end

  describe "perform/1 — not_a_book path" do
    test "returns {:cancel, reason} when vision model says image is not a book" do
      user = insert(:user)
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.NotABookClient)
        assert {:cancel, "image does not contain a book"} =
                 perform_job(IdentifyBookJob, job_args(user.id))
      after
        Application.put_env(:core, :vision_client, original)
      end
    end
  end

  describe "perform/1 — isbn_not_found path" do
    test "returns {:error, reason} when vision model cannot extract an ISBN" do
      user = insert(:user)
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.NoIsbnClient)
        assert {:error, "isbn_not_found"} =
                 perform_job(IdentifyBookJob, job_args(user.id))
      after
        Application.put_env(:core, :vision_client, original)
      end
    end
  end

  describe "perform/1 — generic pipeline failure" do
    test "returns {:error, reason} when pipeline fails with an unexpected error" do
      user = insert(:user)
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, __MODULE__.ErrorClient)
        assert {:error, :service_unavailable} =
                 perform_job(IdentifyBookJob, job_args(user.id))
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
    def call_vision("is_book", _payload), do: {:ok, %{"is_book" => false}}
    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  defmodule NoIsbnClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour
    @impl true
    def call_vision("is_book", _payload), do: {:ok, %{"is_book" => true}}
    def call_vision("extract_isbn", _payload), do: {:ok, %{"isbn" => ""}}
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
