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
  alias Stacks.Books.UploadedImage
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

  describe "the per-image event costs a round-trip, and that is what bounded the drain" do
    # ⛔ The sweeps emitted `image.expired` one row at a time, and `Events.emit/1`
    # is TWO round-trips each — the `event_log` insert plus the subscriber
    # enqueue. Measured on a deployed stack: 200 deletions meant 400 sequential
    # round-trips to a networked Postgres, which ate the sweep's whole
    # 30-second budget, so one run cleared exactly one batch no matter how large
    # the backlog was. Production's 6,655 expired rows were 34 nightly runs from
    # being gone — and the cron fires on roughly a quarter of nights.
    #
    # ⚠️ The property is that the cost does NOT grow with the number of images.
    # A test that only counted events would pass against the per-row version,
    # which emitted exactly the same events; the query count is the only thing
    # that tells the two apart.

    defp count_queries(fun) do
      ref = make_ref()
      test_pid = self()

      # Count only this process's queries. A telemetry handler runs in the
      # process that emitted the event, so comparing against the test pid keeps
      # every other async test's queries out of the number.
      :telemetry.attach(
        "image-retention-query-counter-#{inspect(ref)}",
        [:core, :repo, :query],
        fn _, _, _, _ ->
          if self() == test_pid, do: send(test_pid, {ref, :query})
        end,
        nil
      )

      fun.()
      :telemetry.detach("image-retention-query-counter-#{inspect(ref)}")

      drain_count(ref, 0)
    end

    defp drain_count(ref, acc) do
      receive do
        {^ref, :query} -> drain_count(ref, acc + 1)
      after
        0 -> acc
      end
    end

    defp seed_expired(n) do
      for _ <- 1..n do
        insert(:uploaded_image,
          expires_at: DateTime.add(DateTime.utc_now(), -86_400, :second),
          uploaded_at: DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
        )
      end
    end

    test "sweeping twice as many images does not cost twice as many queries" do
      seed_expired(4)
      few = count_queries(fn -> {:ok, 4} = ImageRetention.cleanup_expired_images(limit: 50) end)

      seed_expired(16)
      many = count_queries(fn -> {:ok, 16} = ImageRetention.cleanup_expired_images(limit: 50) end)

      # Four times the rows. Per-row emission made the query count scale with
      # `n`; batched emission makes the difference a small constant.
      assert many - few <= 3,
             "sweeping 16 images cost #{many} queries against #{few} for 4 — the per-image " <>
               "round-trip is back, so a large backlog will again spend its whole time budget " <>
               "on one batch (measured on production: 6,655 rows at 200 a run)"
    end

    test "every deleted image is still recorded, which is what the batch must not lose" do
      # Anti-vacuity for the test above: a batch that emitted NOTHING would have
      # the flattest query count of all, and the immutable log is meant to be
      # the record that these deletions happened.
      before = event_count("image.expired")
      seed_expired(7)

      assert {:ok, 7} = ImageRetention.cleanup_expired_images(limit: 50)
      assert event_count("image.expired") - before == 7
    end

    test "an empty sweep writes no events and asks the database for nothing extra" do
      assert {:ok, 0} = ImageRetention.cleanup_expired_images(limit: 50)
      assert event_count("image.expired") == 0
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

  describe "cleanup_finished_image_bytes/1 — the photograph goes before the record does" do
    # ⛔ These pin a retention promise the code claimed and did not keep. The
    # architecture says a photo "exists solely to extract a book identifier
    # (ISBN)" and that re-running vision on the original is deliberately not
    # preserved; the retention job's own docstring said images were "deleted
    # immediately by IdentifyBookJob on success". Neither was true: every
    # photograph sat in object storage for the full 30-day ROW ttl.

    defp finished(status, hours_ago, attrs \\ []) do
      at = DateTime.add(DateTime.utc_now(), -hours_ago * 3600, :second)

      insert(
        :uploaded_image,
        Keyword.merge([status: status, uploaded_at: at, updated_at: at], attrs)
      )
    end

    test "a resolved photograph past the retry window is deleted, and its ROW SURVIVES" do
      image = finished("resolved", 25)

      assert {:ok, 1} = ImageRetention.cleanup_finished_image_bytes()

      kept = Repo.get(UploadedImage, image.id)

      # ⚖️ The whole point of the split: the bytes are gone and the record is
      # not. The reader keeps their inbox entry, their export and erasure
      # reachability; the photograph of whoever was in the room does not.
      assert kept != nil
      assert kept.storage_path == nil
      assert kept.status == "resolved"
    end

    test "a rejected photograph is swept too — a wrong answer is still an answer" do
      image = finished("rejected", 25)

      assert {:ok, 1} = ImageRetention.cleanup_finished_image_bytes()

      assert Repo.get(UploadedImage, image.id).storage_path == nil
    end

    test "inside the retry window the photograph is kept, because the reader can still reject" do
      image = finished("resolved", 2)

      assert {:ok, 0} = ImageRetention.cleanup_finished_image_bytes()

      assert Repo.get(UploadedImage, image.id).storage_path != nil
    end

    test "a pending image is never swept, however old — the pipeline has not finished with it" do
      image = finished("pending", 400)

      assert {:ok, 0} = ImageRetention.cleanup_finished_image_bytes()

      assert Repo.get(UploadedImage, image.id).storage_path != nil
    end

    test "a row whose photograph is already gone is not swept again" do
      finished("resolved", 25, storage_path: nil)

      assert {:ok, 0} = ImageRetention.cleanup_finished_image_bytes()
    end

    test "records image.bytes_discarded, NOT image.expired — the image is not gone" do
      finished("resolved", 25)

      before_discarded = event_count("image.bytes_discarded")
      before_expired = event_count("image.expired")

      assert {:ok, 1} = ImageRetention.cleanup_finished_image_bytes()

      # ⛔ An erasure enquiry reads `image.expired` as "this image is gone".
      # Emitting it here would make the log say the record had been deleted
      # while the record is sitting in the table.
      assert event_count("image.bytes_discarded") == before_discarded + 1
      assert event_count("image.expired") == before_expired
    end

    test "the sweep is bounded, and the bound is on the deletes" do
      for _ <- 1..3, do: finished("resolved", 25)

      assert {:ok, 2} = ImageRetention.cleanup_finished_image_bytes(limit: 2)
      assert {:ok, 1} = ImageRetention.cleanup_finished_image_bytes(limit: 2)
      assert {:ok, 0} = ImageRetention.cleanup_finished_image_bytes(limit: 2)
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

  describe "cleanup_orphan_objects/1 — the objects no row points at" do
    # ⛔ EVERY CASE HERE PLANTS A REAL ORPHAN, because a sweep attested clean
    # against a store that contains none proves nothing. That is the mutation
    # probe this issue turns on: the other requirements assert REFUSALS, which
    # a stricter pipeline gives for free.

    test "removes a planted orphan, and the count says how many" do
      user = insert(:user)
      {:ok, %{image_id: kept}} = Stacks.Uploads.init_upload(user.id)
      :ok = Stacks.Uploads.store_upload_bytes(user.id, kept, "a reader's real upload")

      # The orphan: bytes at a key no row points at, which is exactly what a
      # crash between the write and the commit leaves behind.
      {:ok, _} = Stacks.Storage.upload_image(Ecto.UUID.generate(), "row-less bytes")

      {:ok, before_keys} = Stacks.Storage.list_objects("uploads/")
      assert length(before_keys) == 2, "the fixture must contain one of each"

      assert {:ok, 1} = ImageRetention.cleanup_orphan_objects()

      {:ok, after_keys} = Stacks.Storage.list_objects("uploads/")

      assert after_keys == ["uploads/#{kept}"],
             "the orphan must go and the reader's upload must stay"
    end

    test "leaves a store with no orphans alone" do
      # The anti-vacuity control. Without it the case above would pass on a
      # sweep that deleted everything under the prefix.
      user = insert(:user)
      {:ok, %{image_id: image_id}} = Stacks.Uploads.init_upload(user.id)
      :ok = Stacks.Uploads.store_upload_bytes(user.id, image_id, "bytes")

      assert {:ok, 0} = ImageRetention.cleanup_orphan_objects()

      assert {:ok, ["uploads/#{image_id}"]} == Stacks.Storage.list_objects("uploads/")
    end

    test "an object whose row was deleted becomes collectable" do
      # ⚖️ The journey that makes this a GDPR control rather than tidiness: a
      # row goes (erasure, expiry), and until this sweep existed its bytes were
      # unreachable by every mechanism that works from the rows.
      user = insert(:user)
      {:ok, %{image_id: image_id}} = Stacks.Uploads.init_upload(user.id)
      :ok = Stacks.Uploads.store_upload_bytes(user.id, image_id, "bytes to be erased")

      Core.Repo.delete_all(from(i in Stacks.Books.UploadedImage, where: i.id == ^image_id))

      assert {:ok, 1} = ImageRetention.cleanup_orphan_objects()
      assert {:ok, []} = Stacks.Storage.list_objects("uploads/")
    end

    test "finds an orphan that sorts AFTER the batch limit's worth of live keys" do
      # ⛔ THE SWEEP MUST NOT BE BLIND PAST ITS OWN LIMIT. Bounding the KEYS
      # EXAMINED instead of the DELETES looks equivalent and is not: object keys
      # are UUIDs, so a listing's order is arbitrary but STABLE, and the same
      # first N keys come back every run. An orphan below that cut is never
      # examined and the sweep reports `{:ok, 0}` — success — forever.
      user = insert(:user)

      live =
        for _ <- 1..3 do
          {:ok, %{image_id: id}} = Stacks.Uploads.init_upload(user.id)
          :ok = Stacks.Uploads.store_upload_bytes(user.id, id, "a real upload")
          "uploads/#{id}"
        end

      # An orphan guaranteed to sort last: `f` is above every hex digit a UUID
      # can start with, so no amount of luck puts it inside the first page.
      orphan_id = "ffffffff-ffff-4fff-8fff-ffffffffffff"
      {:ok, _} = Stacks.Storage.upload_image(orphan_id, "row-less bytes")

      {:ok, listed} = Stacks.Storage.list_objects("uploads/")
      assert length(listed) == 4

      # `limit: 1` — one delete allowed. The orphan is the 4th key.
      assert {:ok, 1} = ImageRetention.cleanup_orphan_objects(limit: 1)

      {:ok, after_keys} = Stacks.Storage.list_objects("uploads/")

      assert Enum.sort(after_keys) == Enum.sort(live),
             "the orphan past the limit must still be found, and the live keys untouched"
    end

    test "respects its batch limit, like the sweeps above it" do
      for _ <- 1..3, do: Stacks.Storage.upload_image(Ecto.UUID.generate(), "orphan")

      assert {:ok, 2} = ImageRetention.cleanup_orphan_objects(limit: 2)

      {:ok, remaining} = Stacks.Storage.list_objects("uploads/")
      assert length(remaining) == 1
    end
  end

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

    test "cleanup_finished_image_bytes/1 deletes the object for each finished image" do
      at = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)

      insert(:uploaded_image,
        status: "resolved",
        storage_path: "uploads/finished-a",
        uploaded_at: at,
        updated_at: at
      )

      assert {:ok, 1} = ImageRetention.cleanup_finished_image_bytes()

      assert_received {:storage_delete, "uploads/finished-a"}
      refute_received {:storage_delete, _other}
    end
  end

  describe "storage_consistency_check/0 — the standing population, both directions" do
    test "a row whose storage_path resolves to nothing is counted" do
      # ⛔ THE DIRECTION THE ARITHMETIC CHECK CANNOT SEE. "Objects must not
      # exceed rows" is satisfied here — zero objects, one row — while a
      # reader's record points at an image that does not exist. Measured on
      # production 2026-11-05: 2,374 rows in exactly this state, none of which
      # the arithmetic invariant would have reported.
      insert(:uploaded_image, storage_path: "uploads/gone")

      assert {:ok, counts} = ImageRetention.storage_consistency_check()
      assert counts.rows_without_object == 1
      assert counts.rowless_objects == 0
    end

    test "an object no row points at is counted" do
      user = insert(:user)
      {:ok, %{image_id: kept}} = Stacks.Uploads.init_upload(user.id)
      :ok = Stacks.Uploads.store_upload_bytes(user.id, kept, "a reader's real upload")
      {:ok, _} = Stacks.Storage.upload_image(Ecto.UUID.generate(), "row-less bytes")

      assert {:ok, counts} = ImageRetention.storage_consistency_check()
      assert counts.objects == 2
      assert counts.rowless_objects == 1
      assert counts.rows_without_object == 0
    end

    test "both populations at once — the case the arithmetic hides" do
      # ⛔ THE WHOLE ARGUMENT FOR COUNTING BOTH SIDES. One of each means the
      # totals are EQUAL, so "objects must not exceed rows" passes cleanly while
      # two distinct defects stand. On production the difference was 1,860 and
      # the true populations were 4,234 and 2,374 — neither of them 1,860.
      insert(:uploaded_image, storage_path: "uploads/gone")
      {:ok, _} = Stacks.Storage.upload_image(Ecto.UUID.generate(), "row-less bytes")

      assert {:ok, counts} = ImageRetention.storage_consistency_check()
      assert counts.objects == counts.rows_with_path, "the arithmetic invariant holds here"
      assert counts.rowless_objects == 1
      assert counts.rows_without_object == 1
    end

    test "a row with a NULL storage_path is NOT counted as missing its object" do
      # ⚠️ The normal state after `cleanup_finished_image_bytes/1`. Counting it
      # would alarm on every row whose photograph has already been discarded.
      insert(:uploaded_image, storage_path: nil)

      assert {:ok, counts} = ImageRetention.storage_consistency_check()
      assert counts.rows_without_object == 0
    end

    test "the standing count is a gauge, not a collection counter" do
      # ⛔ The distinction this check exists for: `cleanup_orphan_objects/1`
      # reports how many it DELETED, so a sweep that never ran reports the same
      # zero as one that ran and found nothing. A standing population must read
      # the same however many times it is asked.
      insert(:uploaded_image, storage_path: "uploads/gone-a")
      insert(:uploaded_image, storage_path: "uploads/gone-b")

      assert {:ok, first} = ImageRetention.storage_consistency_check()
      assert {:ok, second} = ImageRetention.storage_consistency_check()

      assert first.rows_without_object == 2
      assert second.rows_without_object == 2, "a standing population does not drain by being read"
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

    test "a failed delete LEAVES storage_path alone, rather than manufacturing a row-less object" do
      # ⛔ THE ONE CASE WHERE SWALLOWING THE FAILURE WOULD BE WRONG, and it is
      # the opposite of the two tests either side of it.
      #
      # Those sweeps delete the ROW too, so a leaked object is the lesser harm
      # and the deletion must not be blocked. This sweep KEEPS the row — so if
      # it cleared `storage_path` after a failed delete, the object would
      # survive with nothing pointing at it: unreachable by erasure,
      # unattributable to any reader, and indistinguishable from the population
      # `cleanup_orphan_objects/1` exists to mop up. It would be manufacturing
      # the defect on purpose, nightly.
      at = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)

      image =
        insert(:uploaded_image,
          status: "resolved",
          storage_path: "uploads/doomed-finished",
          uploaded_at: at,
          updated_at: at
        )

      log =
        capture_log(fn ->
          assert {:ok, 0} = ImageRetention.cleanup_finished_image_bytes()
        end)

      assert log =~ "failed to delete storage object uploads/doomed-finished"
      assert log =~ "could not be deleted"

      kept = Repo.get(UploadedImage, image.id)
      assert kept.storage_path == "uploads/doomed-finished"
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
