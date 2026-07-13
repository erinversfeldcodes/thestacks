defmodule Stacks.Workers.ImageRetentionJobTest do
  use Core.DataCase, async: false

  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.GDPR.ImageRetention
  alias Stacks.Workers.ImageRetentionJob

  # The stuck threshold is 2 hours (from ImageRetention @stuck_threshold_hours)
  @stuck_hours 2

  defp image_count(status) do
    "uploaded_images"
    |> where([i], i.status == ^status)
    |> Repo.aggregate(:count, prefix: "op")
  end

  defp total_image_count do
    Repo.aggregate(from(i in "uploaded_images", prefix: "op"), :count)
  end

  defp event_count(event_type) do
    Repo.aggregate(
      from(e in "event_log", prefix: "op", where: e.event_type == ^event_type),
      :count
    )
  end

  describe "cleanup_stuck_images (pending > 2 hours)" do
    test "expires images stuck in pending past threshold" do
      insert(:uploaded_image,
        status: "pending",
        uploaded_at: DateTime.add(DateTime.utc_now(), -(@stuck_hours * 3600 + 60), :second)
      )

      assert :ok = perform_job(ImageRetentionJob, %{})
      assert image_count("pending") == 0
    end

    test "does NOT expire pending images within threshold" do
      insert(:uploaded_image,
        status: "pending",
        uploaded_at: DateTime.add(DateTime.utc_now(), -(@stuck_hours * 3600 - 60), :second)
      )

      assert :ok = perform_job(ImageRetentionJob, %{})
      assert image_count("pending") == 1
    end

    test "does NOT expire resolved images regardless of age" do
      insert(:uploaded_image,
        status: "resolved",
        uploaded_at: DateTime.add(DateTime.utc_now(), -48 * 3600, :second)
      )

      assert :ok = perform_job(ImageRetentionJob, %{})
      assert total_image_count() == 1
    end

    test "emits image.expired event with reason stuck" do
      insert(:uploaded_image,
        status: "pending",
        uploaded_at: DateTime.add(DateTime.utc_now(), -(@stuck_hours * 3600 + 60), :second)
      )

      before = event_count("image.expired")
      assert :ok = perform_job(ImageRetentionJob, %{})
      assert event_count("image.expired") == before + 1
    end
  end

  describe "cleanup_expired_images (expires_at in past)" do
    test "deletes images past their expires_at" do
      insert(:uploaded_image,
        status: "resolved",
        expires_at: DateTime.add(DateTime.utc_now(), -1, :day),
        uploaded_at: DateTime.add(DateTime.utc_now(), -31, :day)
      )

      assert :ok = perform_job(ImageRetentionJob, %{})
      assert total_image_count() == 0
    end

    test "does NOT delete images before their expires_at" do
      insert(:uploaded_image,
        status: "resolved",
        expires_at: DateTime.add(DateTime.utc_now(), 10, :day),
        uploaded_at: DateTime.add(DateTime.utc_now(), -5, :day)
      )

      assert :ok = perform_job(ImageRetentionJob, %{})
      assert total_image_count() == 1
    end
  end

  describe "missing_purge_check (orphan alarm)" do
    test "logs warning for images past expiry still in DB after cleanup" do
      # Insert a resolved image with expires_at in the past.
      # cleanup_stuck won't catch it (not pending).
      # cleanup_expired WILL catch it (expires_at < now).
      # So after the job runs, the image is deleted and missing_purge_check finds nothing.
      #
      # To test missing_purge_check directly, we call it without running cleanup first.
      insert(:uploaded_image,
        status: "resolved",
        expires_at: DateTime.add(DateTime.utc_now(), -1, :day),
        uploaded_at: DateTime.add(DateTime.utc_now(), -31, :day)
      )

      orphans = ImageRetention.missing_purge_check()
      assert length(orphans) == 1
    end
  end

  describe "empty state" do
    test "handles no images gracefully" do
      assert :ok = perform_job(ImageRetentionJob, %{})
    end
  end

  describe "cron registration (Issue #121 §6)" do
    test "is scheduled nightly at 02:00 via the Oban Cron plugin" do
      crontab =
        :core
        |> Application.get_env(Oban)
        |> Keyword.fetch!(:plugins)
        |> Enum.find_value(fn
          {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab)
          _ -> nil
        end)

      assert {"0 2 * * *", ImageRetentionJob} in crontab
    end
  end
end
