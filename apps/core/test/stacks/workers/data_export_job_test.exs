defmodule Stacks.Workers.DataExportJobTest do
  @moduledoc """
  Tests for Stacks.Workers.DataExportJob.

  The worker calls GDPR.Export.export_user_data/1:
  - Returns :ok when the user exists (export succeeds).
  - Returns {:error, _} when the user does not exist (export raises, returning {:error, reason}).
  """

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Workers.DataExportJob

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

  describe "job config (Issue #121 §6)" do
    test "runs on the :default queue" do
      assert DataExportJob.__opts__()[:queue] == :default
    end

    test "is configured with max_attempts of 3" do
      assert DataExportJob.__opts__()[:max_attempts] == 3
    end
  end
end
