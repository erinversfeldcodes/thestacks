defmodule Stacks.Workers.ConfirmDeletionJobTest do
  @moduledoc """
  Tests for Stacks.Workers.ConfirmDeletionJob.

  The worker is a stub that logs and returns :ok regardless of whether the user
  exists. It has two function clauses:
  1. Args with both "user_id" and "email" — sends a confirmation to the email.
  2. Args with only "user_id" — sends a generic confirmation.

  Both clauses return :ok.
  """

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Workers.ConfirmDeletionJob

  describe "perform/1" do
    test "returns :ok with user_id and email args" do
      user = insert(:user)

      assert :ok =
               perform_job(ConfirmDeletionJob, %{
                 "user_id" => user.id,
                 "email" => user.email
               })
    end

    test "returns :ok with only user_id arg" do
      user = insert(:user)

      assert :ok = perform_job(ConfirmDeletionJob, %{"user_id" => user.id})
    end

    test "returns :ok with user_id and email for nonexistent user (stub does not validate)" do
      # The stub does not query the database, so any UUID is accepted.
      assert :ok =
               perform_job(ConfirmDeletionJob, %{
                 "user_id" => Ecto.UUID.generate(),
                 "email" => "deleted@example.com"
               })
    end
  end
end
