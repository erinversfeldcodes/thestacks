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

  describe "the sweeps are bounded, and the drain is what clears a backlog" do
    # ⛔ These pin the fix for a 151-day production retention breach, and the
    # thing they pin is a BOUND rather than a behaviour, so it is easy to delete
    # by accident. Before it, both sweeps took every matching row in one pass:
    # 6,655 expired rows on production meant 6,655 storage deletions and as many
    # event inserts in a single Oban job, on a machine that suspends when idle.
    # The run never finished, nothing rescued the orphaned job, and the backlog
    # grew faster than any run could clear it.
    #
    # So "deletes fewer than exist" is the assertion. A test that only checked
    # the backlog eventually empties would pass against the unbounded version
    # that caused the outage.
    defp expired_image do
      insert(:uploaded_image,
        expires_at: DateTime.add(DateTime.utc_now(), -1, :day),
        uploaded_at: DateTime.add(DateTime.utc_now(), -31, :day)
      )
    end

    test "one sweep deletes at most its limit, leaving the rest for the next run" do
      for _ <- 1..5, do: expired_image()

      assert {:ok, 2} = ImageRetention.cleanup_expired_images(limit: 2),
             "an unbounded sweep would return 5 here — that is the shape that could not finish"

      assert Repo.aggregate(Stacks.Books.UploadedImage, :count) == 3
    end

    test "the stuck sweep is bounded the same way" do
      for _ <- 1..4 do
        insert(:uploaded_image,
          status: "pending",
          uploaded_at: DateTime.add(DateTime.utc_now(), -3, :hour)
        )
      end

      assert {:ok, 2} = ImageRetention.cleanup_stuck_images(limit: 2)
      assert Repo.aggregate(Stacks.Books.UploadedImage, :count) == 2
    end

    test "drain clears the whole backlog in batches and reports it drained" do
      for _ <- 1..5, do: expired_image()

      assert {:ok, 5, :drained} =
               ImageRetention.drain(&ImageRetention.cleanup_expired_images/1, limit: 2)

      assert Repo.aggregate(Stacks.Books.UploadedImage, :count) == 0
    end

    test "drain reports :deadline rather than claiming a backlog it did not clear" do
      for _ <- 1..5, do: expired_image()

      # A budget already spent: the first batch runs, then the deadline check
      # fires. The point is the RETURN VALUE — a sweep that stopped early must
      # not be indistinguishable from one that finished, because the job logs
      # `:ok` either way and that is precisely how the backlog stayed invisible.
      assert {:ok, 2, :deadline} =
               ImageRetention.drain(&ImageRetention.cleanup_expired_images/1,
                 limit: 2,
                 budget_ms: 0
               )

      assert Repo.aggregate(Stacks.Books.UploadedImage, :count) == 3
    end

    test "drain on an empty backlog is a no-op that still reports drained" do
      assert {:ok, 0, :drained} =
               ImageRetention.drain(&ImageRetention.cleanup_expired_images/1, limit: 2)
    end
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
      `self` here is the test process, so the message lands in its mailbox.
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
  def list(_prefix), do: {:ok, []}

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
  def list(_prefix), do: {:ok, []}

  @impl true
  def delete(_key), do: {:error, :simulated_storage_outage}
end

defmodule Stacks.GDPR.ImageRetentionStorageTest do
  @moduledoc """
      Storage-side assertions for the 30-day image-deletion promise. These swap the globally-configured `:storage` backend, so the
      module runs `async: false` and restores `Stacks.Storage.Mock` on exit.
  """

  use Core.DataCase, async: false

  import Stacks.Factory
  import ExUnit.CaptureLog

  alias Core.Repo
  alias Stacks.Books.UploadedImage
  alias Stacks.GDPR.ImageRetention
  alias Stacks.GDPR.ImageRetentionTest.FailingStorage
  alias Stacks.GDPR.ImageRetentionTest.RecordingStorage

  describe "storage deletion is invoked per row" do
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

  describe "storage failure never blocks DB cleanup" do
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
