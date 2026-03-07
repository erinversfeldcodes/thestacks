defmodule Stacks.Workers.RecalculateWearJobTest do
  @moduledoc """
  Tests for Stacks.Workers.RecalculateWearJob.

  The worker calls Shelving.spine_data/1:
  - Returns :ok when a placement exists.
  - Returns {:cancel, "placement not found"} when placement_id is unknown.
  """

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Workers.RecalculateWearJob

  describe "perform/1" do
    test "returns :ok for an existing placement_id" do
      user = insert(:user)
      shelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: shelf, book: book)

      assert :ok = perform_job(RecalculateWearJob, %{"placement_id" => placement.id})
    end

    test "returns {:cancel, reason} for a nonexistent placement_id" do
      assert {:cancel, "placement not found"} =
               perform_job(RecalculateWearJob, %{"placement_id" => Ecto.UUID.generate()})
    end
  end
end
