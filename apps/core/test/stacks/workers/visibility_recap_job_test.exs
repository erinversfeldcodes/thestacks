defmodule Stacks.Workers.VisibilityRecapJobTest do
  @moduledoc """
      Tests for Stacks.Workers.VisibilityRecapJob.

      The worker batches-updates bookshelves and placements whose stored visibility
      violates the user's new (more restrictive) profile_visibility ceiling, then
      emits a user.visibility_recap_completed event with the counts.
  """

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Blog.Post
  alias Stacks.Shelving.{Bookshelf, Placement}
  alias Stacks.Workers.VisibilityRecapJob

  defp event_count(event_type) do
    Repo.aggregate(
      from(e in "event_log", prefix: "op", where: e.event_type == ^event_type),
      :count
    )
  end

  defp recap_payload(user_id) do
    Repo.one(
      from(e in "event_log",
        prefix: "op",
        where:
          e.event_type == "user.visibility_recap_completed" and
            e.aggregate_id == ^user_id,
        order_by: [desc: e.occurred_at],
        limit: 1,
        select: e.payload
      )
    )
  end

  describe "perform/1 — ceiling: owner" do
    test "caps bookshelves stored as platform to owner" do
      user = insert(:user)
      _bs = insert(:bookshelf, user: user, name: "library", visibility: "platform")

      perform_job(VisibilityRecapJob, %{"user_id" => user.id, "new_visibility" => "owner"})

      reloaded = Repo.get_by!(Bookshelf, user_id: user.id, name: "library")
      assert reloaded.visibility == "owner"
    end

    test "caps placements stored as platform to owner" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")
      book = insert(:book)
      _placement = insert(:placement, bookshelf: bookshelf, book: book, visibility: "platform")

      perform_job(VisibilityRecapJob, %{"user_id" => user.id, "new_visibility" => "owner"})

      reloaded = Repo.get_by!(Placement, bookshelf_id: bookshelf.id, book_id: book.id)
      assert reloaded.visibility == "owner"
    end

    test "returns :ok" do
      user = insert(:user)
      _bs = insert(:bookshelf, user: user, name: "library", visibility: "platform")

      assert :ok =
               perform_job(VisibilityRecapJob, %{
                 "user_id" => user.id,
                 "new_visibility" => "owner"
               })
    end

    test "emits user.visibility_recap_completed event" do
      user = insert(:user)
      _bs = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      before_count = event_count("user.visibility_recap_completed")

      perform_job(VisibilityRecapJob, %{"user_id" => user.id, "new_visibility" => "owner"})

      assert event_count("user.visibility_recap_completed") == before_count + 1
    end

    test "event payload includes correct bookshelves_capped count" do
      user = insert(:user)
      _bs1 = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      _bs2 = insert(:bookshelf, user: user, name: "wishlist", visibility: "platform")

      perform_job(VisibilityRecapJob, %{"user_id" => user.id, "new_visibility" => "owner"})

      event =
        Repo.one(
          from(e in "event_log",
            prefix: "op",
            where:
              e.event_type == "user.visibility_recap_completed" and
                e.aggregate_id == ^user.id,
            order_by: [desc: e.occurred_at],
            limit: 1,
            select: e.payload
          )
        )

      assert event["bookshelves_capped"] == 2
    end

    test "does not touch bookshelves already at owner" do
      user = insert(:user)
      bs = insert(:bookshelf, user: user, name: "library", visibility: "owner")

      perform_job(VisibilityRecapJob, %{"user_id" => user.id, "new_visibility" => "owner"})

      reloaded = Repo.get!(Bookshelf, bs.id)
      assert reloaded.visibility == "owner"
      assert reloaded.updated_at == bs.updated_at
    end

    test "does not touch another user's bookshelves" do
      user = insert(:user)
      other_user = insert(:user)
      other_bs = insert(:bookshelf, user: other_user, name: "library", visibility: "platform")

      perform_job(VisibilityRecapJob, %{"user_id" => user.id, "new_visibility" => "owner"})

      reloaded = Repo.get!(Bookshelf, other_bs.id)
      assert reloaded.visibility == "platform"
    end
  end

  describe "perform/1 — ceiling: platform" do
    test "does not cap bookshelves already at platform" do
      user = insert(:user)
      bs = insert(:bookshelf, user: user, name: "library", visibility: "platform")

      perform_job(VisibilityRecapJob, %{"user_id" => user.id, "new_visibility" => "platform"})

      reloaded = Repo.get!(Bookshelf, bs.id)
      assert reloaded.visibility == "platform"
      assert reloaded.updated_at == bs.updated_at
    end

    test "returns :ok with no DB changes when nothing to cap" do
      user = insert(:user)
      _bs = insert(:bookshelf, user: user, name: "library", visibility: "platform")

      assert :ok =
               perform_job(VisibilityRecapJob, %{
                 "user_id" => user.id,
                 "new_visibility" => "platform"
               })
    end

    test "does not emit event when ceiling is platform and nothing is capped" do
      user = insert(:user)
      _bs = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      before_count = event_count("user.visibility_recap_completed")

      perform_job(VisibilityRecapJob, %{"user_id" => user.id, "new_visibility" => "platform"})

      assert event_count("user.visibility_recap_completed") == before_count
    end
  end

  describe "perform/1 — posts capped via tighten_posts_to_ceiling" do
    test "caps posts more visible than the ceiling and reports posts_capped in payload" do
      user = insert(:user, profile_visibility: "platform")
      platform_post = insert(:post, user: user, visibility: "platform")
      owner_post = insert(:post, user: user, visibility: "owner")

      perform_job(VisibilityRecapJob, %{"user_id" => user.id, "new_visibility" => "owner"})

      assert Repo.get!(Post, platform_post.id).visibility == "owner"
      assert Repo.get!(Post, owner_post.id).visibility == "owner"

      payload = recap_payload(user.id)
      assert payload["posts_capped"] == 1
    end

    test "reports posts_capped: 0 when no posts violate the ceiling" do
      user = insert(:user, profile_visibility: "platform")
      _owner_post = insert(:post, user: user, visibility: "owner")
      _bs = insert(:bookshelf, user: user, name: "library", visibility: "platform")

      perform_job(VisibilityRecapJob, %{"user_id" => user.id, "new_visibility" => "owner"})

      payload = recap_payload(user.id)
      assert payload["posts_capped"] == 0
    end
  end

  describe "perform/1 — placement_count in payload" do
    test "event payload includes correct placements_capped count" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")
      book1 = insert(:book)
      book2 = insert(:book)
      _p1 = insert(:placement, bookshelf: bookshelf, book: book1, visibility: "platform")
      _p2 = insert(:placement, bookshelf: bookshelf, book: book2, visibility: "platform")

      perform_job(VisibilityRecapJob, %{"user_id" => user.id, "new_visibility" => "owner"})

      event =
        Repo.one(
          from(e in "event_log",
            prefix: "op",
            where:
              e.event_type == "user.visibility_recap_completed" and
                e.aggregate_id == ^user.id,
            order_by: [desc: e.occurred_at],
            limit: 1,
            select: e.payload
          )
        )

      assert event["placements_capped"] == 2
    end
  end
end
