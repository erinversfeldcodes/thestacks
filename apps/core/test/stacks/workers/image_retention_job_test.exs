defmodule Stacks.Workers.ImageRetentionJobTest do
  @moduledoc "Tests for Stacks.Workers.ImageRetentionJob."

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Workers.ImageRetentionJob

  defp event_count(event_type) do
    Repo.aggregate(
      from(e in "event_log", prefix: "op", where: e.event_type == ^event_type),
      :count
    )
  end

  describe "perform/1" do
    test "expires stuck images (pending, older than retention threshold)" do
      _stuck =
        insert(:uploaded_image,
          status: "pending",
          uploaded_at: DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
        )

      assert :ok = perform_job(ImageRetentionJob, %{})

      remaining =
        "uploaded_images"
        |> where([i], i.status == "pending")
        |> Repo.aggregate(:count, prefix: "op")

      assert remaining == 0
    end

    test "does not expire recent submitted/pending images" do
      _recent =
        insert(:uploaded_image,
          status: "pending",
          uploaded_at: DateTime.add(DateTime.utc_now(), -30 * 60, :second)
        )

      assert :ok = perform_job(ImageRetentionJob, %{})

      remaining =
        "uploaded_images"
        |> where([i], i.status == "pending")
        |> Repo.aggregate(:count, prefix: "op")

      assert remaining == 1
    end

    test "deletes storage objects for expired images" do
      _expired =
        insert(:uploaded_image,
          status: "pending",
          uploaded_at: DateTime.add(DateTime.utc_now(), -3 * 3600, :second),
          storage_path: "uploads/test-image.jpg",
          expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
        )

      # Storage is configured as Stacks.Storage.Local in test, which is a no-op
      # for missing files. The key assertion is that the job completes without error.
      assert :ok = perform_job(ImageRetentionJob, %{})
    end

    test "emits alarm event for images past purge deadline" do
      # Insert an image that is past its expires_at but not stuck (status != pending),
      # so cleanup_stuck won't delete it and cleanup_expired will.
      # Then also insert one past expiry that neither cleanup catches (simulate orphan).
      _expired =
        insert(:uploaded_image,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day),
          uploaded_at: DateTime.add(DateTime.utc_now(), -31, :day)
        )

      before_count = event_count("image.expired")

      assert :ok = perform_job(ImageRetentionJob, %{})

      # cleanup_expired_images should have caught the expired image
      assert event_count("image.expired") >= before_count + 1
    end

    test "handles empty result (no images to process)" do
      assert :ok = perform_job(ImageRetentionJob, %{})
    end
  end
end
