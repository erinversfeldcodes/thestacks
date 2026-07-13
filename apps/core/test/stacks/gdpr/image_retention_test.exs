defmodule Stacks.GDPR.ImageRetentionTest do
  @moduledoc """
  Tests for Stacks.GDPR.ImageRetention.

  Verifies that expired/stuck images are deleted and that an `image.expired`
  event is emitted for each deleted record.
  """

  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.GDPR.ImageRetention

  defp event_count(event_type) do
    Repo.aggregate(
      from(e in "event_log", prefix: "op", where: e.event_type == ^event_type),
      :count
    )
  end

  describe "cleanup_expired_images/0" do
    test "deletes images past their expires_at" do
      _expired =
        insert(:uploaded_image,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day),
          uploaded_at: DateTime.add(DateTime.utc_now(), -31, :day)
        )

      assert {:ok, 1} = ImageRetention.cleanup_expired_images()
    end

    test "does not delete images not yet expired" do
      _fresh = insert(:uploaded_image, expires_at: DateTime.add(DateTime.utc_now(), 29, :day))

      assert {:ok, 0} = ImageRetention.cleanup_expired_images()
    end

    test "emits image.expired event for each deleted record" do
      _expired1 =
        insert(:uploaded_image,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day),
          uploaded_at: DateTime.add(DateTime.utc_now(), -31, :day)
        )

      _expired2 =
        insert(:uploaded_image,
          expires_at: DateTime.add(DateTime.utc_now(), -2, :day),
          uploaded_at: DateTime.add(DateTime.utc_now(), -32, :day)
        )

      before_count = event_count("image.expired")

      ImageRetention.cleanup_expired_images()

      assert event_count("image.expired") == before_count + 2
    end

    test "returns {:ok, 0} and emits no events when nothing is expired" do
      before_count = event_count("image.expired")

      assert {:ok, 0} = ImageRetention.cleanup_expired_images()

      assert event_count("image.expired") == before_count
    end
  end

  describe "cleanup_stuck_images/0" do
    test "deletes pending images stuck for more than 2 hours" do
      _stuck =
        insert(:uploaded_image,
          status: "pending",
          uploaded_at: DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
        )

      assert {:ok, 1} = ImageRetention.cleanup_stuck_images()
    end

    test "does not delete pending images uploaded recently" do
      _recent =
        insert(:uploaded_image,
          status: "pending",
          uploaded_at: DateTime.add(DateTime.utc_now(), -30 * 60, :second)
        )

      assert {:ok, 0} = ImageRetention.cleanup_stuck_images()
    end

    test "does not delete non-pending images regardless of age" do
      _resolved =
        insert(:uploaded_image,
          status: "resolved",
          uploaded_at: DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
        )

      assert {:ok, 0} = ImageRetention.cleanup_stuck_images()
    end

    test "emits image.expired event for each stuck image deleted" do
      _stuck =
        insert(:uploaded_image,
          status: "pending",
          uploaded_at: DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
        )

      before_count = event_count("image.expired")

      ImageRetention.cleanup_stuck_images()

      assert event_count("image.expired") == before_count + 1
    end
  end
end

defmodule Stacks.GDPR.ImageRetentionTest.RecordingStorage do
  @moduledoc """
  Test-local storage backend that records every `delete/1` call by sending
  `{:storage_delete, key}` to the process that ran the cleanup. Because
  `ImageRetention.delete_storage_objects/1` runs synchronously in the caller,
  `self()` here is the test process, so the message lands in its mailbox.
  """

  @behaviour Stacks.Storage.StorageBehaviour

  @impl true
  def put(key, _data, _opts \\ []), do: {:ok, key}

  @impl true
  def presigned_url(key, _ttl_seconds \\ 900), do: {:ok, key}

  @impl true
  def presigned_put_url(key, _ttl_seconds \\ 900, _opts \\ []), do: {:ok, key}

  @impl true
  def head(_key), do: {:error, :not_found}

  @impl true
  def delete(key) do
    send(self(), {:storage_delete, key})
    :ok
  end
end

defmodule Stacks.GDPR.ImageRetentionTest.FailingStorage do
  @moduledoc """
  Test-local storage backend whose `delete/1` always fails. Proves that a
  storage-layer failure is logged but never blocks DB cleanup.
  """

  @behaviour Stacks.Storage.StorageBehaviour

  @impl true
  def put(key, _data, _opts \\ []), do: {:ok, key}

  @impl true
  def presigned_url(key, _ttl_seconds \\ 900), do: {:ok, key}

  @impl true
  def presigned_put_url(key, _ttl_seconds \\ 900, _opts \\ []), do: {:ok, key}

  @impl true
  def head(_key), do: {:error, :not_found}

  @impl true
  def delete(_key), do: {:error, :simulated_storage_outage}
end

defmodule Stacks.GDPR.ImageRetentionStorageTest do
  @moduledoc """
  Storage-side assertions for the 30-day image-deletion promise (Issue #121,
  Phase 3). These swap the globally-configured `:storage` backend, so the
  module runs `async: false` and restores `Stacks.Storage.Mock` on exit.
  """

  # async: false — swaps the global :storage Application env.
  use Core.DataCase, async: false

  import Stacks.Factory
  import ExUnit.CaptureLog

  alias Core.Repo
  alias Stacks.Books.UploadedImage
  alias Stacks.GDPR.ImageRetention
  alias Stacks.GDPR.ImageRetentionTest.FailingStorage
  alias Stacks.GDPR.ImageRetentionTest.RecordingStorage

  describe "storage deletion is invoked per row (punch #10)" do
    setup do
      Application.put_env(:core, :storage, RecordingStorage)
      on_exit(fn -> Application.put_env(:core, :storage, Stacks.Storage.Mock) end)
      :ok
    end

    test "cleanup_expired_images/0 calls Storage.delete_image once per expired image" do
      insert(:uploaded_image,
        storage_path: "uploads/expired-a",
        expires_at: DateTime.add(DateTime.utc_now(), -1, :day),
        uploaded_at: DateTime.add(DateTime.utc_now(), -31, :day)
      )

      insert(:uploaded_image,
        storage_path: "uploads/expired-b",
        expires_at: DateTime.add(DateTime.utc_now(), -2, :day),
        uploaded_at: DateTime.add(DateTime.utc_now(), -32, :day)
      )

      assert {:ok, 2} = ImageRetention.cleanup_expired_images()

      assert_received {:storage_delete, "uploads/expired-a"}
      assert_received {:storage_delete, "uploads/expired-b"}
      refute_received {:storage_delete, _other}
    end

    test "cleanup_stuck_images/0 calls Storage.delete_image once per stuck image" do
      insert(:uploaded_image,
        status: "pending",
        storage_path: "uploads/stuck-a",
        uploaded_at: DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
      )

      insert(:uploaded_image,
        status: "pending",
        storage_path: "uploads/stuck-b",
        uploaded_at: DateTime.add(DateTime.utc_now(), -4 * 3600, :second)
      )

      assert {:ok, 2} = ImageRetention.cleanup_stuck_images()

      assert_received {:storage_delete, "uploads/stuck-a"}
      assert_received {:storage_delete, "uploads/stuck-b"}
      refute_received {:storage_delete, _other}
    end
  end

  describe "storage failure never blocks DB cleanup (punch #11)" do
    setup do
      Application.put_env(:core, :storage, FailingStorage)
      on_exit(fn -> Application.put_env(:core, :storage, Stacks.Storage.Mock) end)
      :ok
    end

    test "expired-image cleanup logs a warning and still deletes the DB record on storage failure" do
      expired =
        insert(:uploaded_image,
          storage_path: "uploads/doomed-expired",
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day),
          uploaded_at: DateTime.add(DateTime.utc_now(), -31, :day)
        )

      log =
        capture_log(fn ->
          assert {:ok, 1} = ImageRetention.cleanup_expired_images()
        end)

      assert log =~ "failed to delete storage object uploads/doomed-expired"
      assert log =~ "simulated_storage_outage"

      # Storage failure must not resurrect the DB row — no infinite retry.
      assert Repo.get(UploadedImage, expired.id) == nil
    end

    test "stuck-image cleanup logs a warning and still deletes the DB record on storage failure" do
      stuck =
        insert(:uploaded_image,
          status: "pending",
          storage_path: "uploads/doomed-stuck",
          uploaded_at: DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
        )

      log =
        capture_log(fn ->
          assert {:ok, 1} = ImageRetention.cleanup_stuck_images()
        end)

      assert log =~ "failed to delete storage object uploads/doomed-stuck"
      assert log =~ "simulated_storage_outage"

      assert Repo.get(UploadedImage, stuck.id) == nil
    end
  end
end
