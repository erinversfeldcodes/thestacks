defmodule Stacks.Workers.ExportRetentionJobTest do
  @moduledoc """
      Tests for Stacks.Workers.ExportRetentionJob — the sweep that stops a GDPR
      export becoming a permanent second copy of somebody's personal data.
  """

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  alias Stacks.GDPR.ExportDelivery
  alias Stacks.Storage
  alias Stacks.Workers.ExportRetentionJob

  setup do
    Storage.Mock.clear()
    on_exit(&Storage.Mock.clear/0)
    :ok
  end

  defp seed_export(user_id, ttl_seconds) do
    key = ExportDelivery.key_for(user_id, DateTime.add(DateTime.utc_now(), ttl_seconds, :second))
    Storage.Mock.seed(key, ~s({"user":{"id":"#{user_id}"}}))
    key
  end

  test "deletes exports past their deadline" do
    key = seed_export(Ecto.UUID.generate(), -60)

    assert :ok = perform_job(ExportRetentionJob, %{})
    assert Storage.Mock.get(key) == nil
  end

  test "leaves an export whose link is still live" do
    key = seed_export(Ecto.UUID.generate(), 3600)

    assert :ok = perform_job(ExportRetentionJob, %{})
    refute Storage.Mock.get(key) == nil
  end

  test "fails the job when an expired object survives, so Oban retries" do
    seed_export(Ecto.UUID.generate(), -60)
    Storage.Mock.steer_error(:delete, :circuit_open)

    assert {:error, {:export_objects_survived_expiry, 1}} =
             perform_job(ExportRetentionJob, %{})
  end

  test "runs hourly so an object outlives its link by an hour at most" do
    crontab =
      :core
      |> Application.get_env(Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
        _ -> nil
      end)

    assert Enum.any?(crontab, fn
             {expression, ExportRetentionJob} -> String.ends_with?(expression, " * * * *")
             _ -> false
           end)
  end

  test "is configured with max_attempts of 3" do
    assert ExportRetentionJob.__opts__()[:max_attempts] == 3
  end
end
