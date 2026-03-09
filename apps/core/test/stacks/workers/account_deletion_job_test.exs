defmodule Stacks.Workers.AccountDeletionJobTest do
  @moduledoc """
  Tests for Stacks.Workers.AccountDeletionJob.

  The worker calls GDPR.Deletion.delete_user_data/1:
  - Returns :ok when user exists and all data is deleted.
  - Returns {:error, _} when user does not exist (Ecto.NoResultsError raised
    inside the Multi at the :delete_user step, causing the transaction to fail).

  Deletion is NOT idempotent — calling it a second time after the user is
  already deleted will fail because Repo.get!/1 raises for the missing user.
  """

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Workers.AccountDeletionJob

  describe "perform/1" do
    test "returns :ok and deletes user data for a valid user_id" do
      user = insert(:user)

      assert :ok = perform_job(AccountDeletionJob, %{"user_id" => user.id})

      # User should no longer exist
      assert is_nil(Core.Repo.get(Stacks.Accounts.User, user.id))
    end

    test "returns {:error, _} for a nonexistent user_id" do
      # The Multi fails at :delete_user when Repo.get! raises for unknown user
      assert {:error, _reason} =
               perform_job(AccountDeletionJob, %{"user_id" => Ecto.UUID.generate()})
    end
  end
end
