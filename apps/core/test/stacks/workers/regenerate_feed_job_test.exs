defmodule Stacks.Workers.RegenerateFeedJobTest do
  @moduledoc "Tests for Stacks.Workers.RegenerateFeedJob."

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Workers.RegenerateFeedJob

  # ---------------------------------------------------------------------------
  # perform/1 — valid user + platform-visible bookshelf
  # ---------------------------------------------------------------------------

  describe "perform/1 — platform-visible bookshelf" do
    test "regenerates feed and returns :ok" do
      user = insert(:user, profile_visibility: "platform")
      _bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")

      assert :ok =
               perform_job(RegenerateFeedJob, %{
                 "user_id" => user.id,
                 "bookshelf_name" => "library"
               })
    end
  end

  # ---------------------------------------------------------------------------
  # perform/1 — non-existent user
  # ---------------------------------------------------------------------------

  describe "perform/1 — non-existent user" do
    test "returns {:cancel, _} when user/bookshelf not found" do
      assert {:cancel, "bookshelf not found"} =
               perform_job(RegenerateFeedJob, %{
                 "user_id" => Ecto.UUID.generate(),
                 "bookshelf_name" => "library"
               })
    end
  end

  # ---------------------------------------------------------------------------
  # perform/1 — owner-visibility bookshelf (non-public)
  # ---------------------------------------------------------------------------

  describe "perform/1 — owner-visibility bookshelf" do
    test "returns :ok and skips feed generation for non-public shelf" do
      user = insert(:user)
      _bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")

      assert :ok =
               perform_job(RegenerateFeedJob, %{
                 "user_id" => user.id,
                 "bookshelf_name" => "library"
               })
    end
  end

  # ---------------------------------------------------------------------------
  # perform/1 — missing or malformed args
  # ---------------------------------------------------------------------------

  describe "perform/1 — missing args" do
    test "returns {:cancel, _} for empty args" do
      assert {:cancel, "invalid args"} = perform_job(RegenerateFeedJob, %{})
    end

    test "returns {:cancel, _} when user_id is present but bookshelf_name is missing" do
      assert {:cancel, "invalid args"} =
               perform_job(RegenerateFeedJob, %{"user_id" => Ecto.UUID.generate()})
    end

    test "returns {:cancel, _} when bookshelf_name is present but user_id is missing" do
      assert {:cancel, "invalid args"} =
               perform_job(RegenerateFeedJob, %{"bookshelf_name" => "library"})
    end
  end
end
