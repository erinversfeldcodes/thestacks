defmodule Stacks.Workers.ImageRetentionJobTest do
  use Core.DataCase, async: false

  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.GDPR.ImageRetention
  alias Stacks.Workers.ImageRetentionJob

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

  describe "cron registration" do
    test "⛔ is NOT in the Oban crontab, because that node scales to zero" do
      # Oban's Cron plugin computes due jobs on a tick from a running node and
      # has no catch-up pass, so an entry fires only if something else happened
      # to wake the machine in that minute. Production's `oban_jobs` showed
      # exactly that: every retention row inserted at 02:00:00, picked up within
      # a second, frozen at attempt 1 with a different node UUID each night.
      refute ImageRetentionJob in Enum.map(crontab(), &elem(&1, 1)),
             "the 30-day image retention commitment is back on a trigger that fires only when " <>
               "the machine happens to be awake"
    end

    test "is scheduled nightly at 02:00 by the workflow that replaced the crontab entry" do
      workflow = scheduled_core_jobs()

      assert workflow =~ ~s(- cron: "0 2 * * *"),
             "the 02:00 cadence is gone from the workflow, so the duty has no schedule anywhere"

      assert workflow =~ "Stacks.Release.sweep_images",
             "the workflow carries the cadence but never invokes the duty"
    end

    defp crontab do
      :core
      |> Application.get_env(Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab)
        _ -> nil
      end)
    end

    # The duty's schedule moved from the Oban crontab to a workflow, so the
    # cadence claim is read off the workflow. ⚠️ Kept as a claim rather than
    # deleted: "it runs at this hour" is the behavioural promise, and dropping it
    # because the trigger moved would quietly discard the only thing asserting
    # the duty has a cadence at all.
    defp scheduled_core_jobs do
      File.read!(Path.expand("../../../../../.github/workflows/scheduled-core-jobs.yml", __DIR__))
    end
  end
end
