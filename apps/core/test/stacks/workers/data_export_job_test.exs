defmodule Stacks.Workers.DataExportJobTest do
  @moduledoc """
      Tests for Stacks.Workers.DataExportJob.

      The worker gathers the export (GDPR.Export) and then delivers it
      (GDPR.ExportDelivery). Generating an export nobody receives is the exact
      failure this worker used to have, so the delivery assertions below —
      object stored, link signed, email enqueued — are the ones that matter;
      `:ok` on its own proves nothing.
  """

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Email.Templates
  alias Stacks.GDPR.ExportDelivery
  alias Stacks.Storage
  alias Stacks.Workers.DataExportJob
  alias Stacks.Workers.EmailDeliveryJob

  setup do
    Storage.Mock.clear()
    on_exit(&Storage.Mock.clear/0)
    :ok
  end

  describe "perform/1" do
    test "returns :ok for a valid user_id" do
      user = insert(:user)

      assert :ok = perform_job(DataExportJob, %{"user_id" => user.id})
    end

    test "returns {:error, _} for a nonexistent user_id" do
      assert {:error, _reason} =
               perform_job(DataExportJob, %{"user_id" => Ecto.UUID.generate()})
    end
  end

  describe "delivery" do
    test "stores the export where only a signed link can reach it" do
      user = insert(:user)

      assert :ok = perform_job(DataExportJob, %{"user_id" => user.id})

      assert {:ok, [key]} = Storage.list_objects("exports/#{user.id}/")
      assert String.ends_with?(key, ".json")
      assert {:ok, export} = Jason.decode(Storage.Mock.get(key))
      assert export["user"]["email"] == user.email
    end

    test "stamps the stored object with the TTL that governs its deletion" do
      user = insert(:user)
      before = DateTime.utc_now()

      assert :ok = perform_job(DataExportJob, %{"user_id" => user.id})

      assert {:ok, [key]} = Storage.list_objects("exports/#{user.id}/")
      assert {:ok, deadline} = ExportDelivery.deadline(key)
      assert DateTime.diff(deadline, before) in 86_395..86_400
    end

    test "enqueues the export-ready email with a link to the stored object" do
      user = insert(:user)

      assert :ok = perform_job(DataExportJob, %{"user_id" => user.id})

      assert {:ok, [key]} = Storage.list_objects("exports/#{user.id}/")

      assert [job] = all_enqueued(worker: EmailDeliveryJob)
      assert job.args["template"] == "gdpr_export_ready"
      assert job.args["user_id"] == user.id
      assert job.args["params"]["download_url"] =~ key
      assert job.args["params"]["expires_in_seconds"] == 86_400
    end

    test "the enqueued args are ones the email worker accepts and renders" do
      user = insert(:user)

      assert :ok = perform_job(DataExportJob, %{"user_id" => user.id})
      assert [job] = all_enqueued(worker: EmailDeliveryJob)
      assert :ok = perform_job(EmailDeliveryJob, job.args)

      %{"download_url" => url, "expires_in_seconds" => ttl} = job.args["params"]
      body = Templates.gdpr_export_ready(url, ttl)

      assert body =~ ~s(href="#{url}")
      assert body =~ "expire in 24 hours"
    end

    test "the email states the expiry the link actually has, not a fixed promise" do
      assert Templates.gdpr_export_ready("https://example.test/x", 86_400) =~ "expire in 24 hours"
      assert Templates.gdpr_export_ready("https://example.test/x", 3600) =~ "expire in 1 hour"
      assert Templates.gdpr_export_ready("https://example.test/x", 120) =~ "expire in 2 minutes"
    end

    test "a storage failure fails the job so Oban retries it" do
      user = insert(:user)
      Storage.Mock.steer_error(:put, :circuit_open)

      assert {:error, :circuit_open} = perform_job(DataExportJob, %{"user_id" => user.id})
      refute_enqueued(worker: EmailDeliveryJob)
    end

    test "a signing failure fails the job rather than mailing a dead link" do
      user = insert(:user)
      Storage.Mock.steer_error(:presign, :signing_unavailable)

      assert {:error, :signing_unavailable} =
               perform_job(DataExportJob, %{"user_id" => user.id})

      refute_enqueued(worker: EmailDeliveryJob)
    end
  end

  describe "job config" do
    test "runs on the :default queue" do
      assert DataExportJob.__opts__()[:queue] == :default
    end

    test "is configured with max_attempts of 3" do
      assert DataExportJob.__opts__()[:max_attempts] == 3
    end
  end
end
