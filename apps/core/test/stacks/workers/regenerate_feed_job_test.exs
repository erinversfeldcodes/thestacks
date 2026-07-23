defmodule Stacks.Workers.RegenerateFeedJobTest do
  @moduledoc "Tests for Stacks.Workers.RegenerateFeedJob."

  # async: false — mutates the global :feed_cache_writer env seam (see FeedsTest).
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Feeds.FeedCacheEntry
  alias Stacks.Workers.RegenerateFeedJob

  defp cache_rows(bookshelf_id) do
    Repo.all(from fc in FeedCacheEntry, where: fc.bookshelf_id == ^bookshelf_id)
  end

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
  # perform/1 — writes the feed_cache row (Issue #264)
  # ---------------------------------------------------------------------------

  describe "perform/1 — feed_cache write" do
    test "upserts a feed_cache row holding the generated Atom XML + etag" do
      user = insert(:user, display_name: "Erin", profile_visibility: "platform")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "The Secret History")
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      assert [] = cache_rows(bookshelf.id)

      assert :ok =
               perform_job(RegenerateFeedJob, %{
                 "user_id" => user.id,
                 "bookshelf_name" => "library"
               })

      assert [row] = cache_rows(bookshelf.id)
      assert row.atom_xml =~ "<feed xmlns="
      assert row.atom_xml =~ "The Secret History"
      # etag is the pure MD5 of the stored XML
      assert row.etag == Stacks.Feeds.compute_etag(row.atom_xml)
    end

    test "is idempotent — two identical runs leave one row with the same etag" do
      user = insert(:user, profile_visibility: "platform")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "Stable Book")
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      args = %{"user_id" => user.id, "bookshelf_name" => "library"}

      assert :ok = perform_job(RegenerateFeedJob, args)
      assert [first] = cache_rows(bookshelf.id)

      assert :ok = perform_job(RegenerateFeedJob, args)
      assert [second] = cache_rows(bookshelf.id)

      assert first.id == second.id, "upsert must not create a second row"
      assert first.etag == second.etag, "unchanged data ⇒ stable etag"
    end

    test "writes no row for an owner-visibility (non-public) bookshelf" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")

      assert :ok =
               perform_job(RegenerateFeedJob, %{
                 "user_id" => user.id,
                 "bookshelf_name" => "library"
               })

      assert [] = cache_rows(bookshelf.id)
    end

    test "writes no row and cancels for a missing bookshelf" do
      assert {:cancel, _} =
               perform_job(RegenerateFeedJob, %{
                 "user_id" => Ecto.UUID.generate(),
                 "bookshelf_name" => "library"
               })

      assert [] = Repo.all(FeedCacheEntry)
    end
  end

  # ---------------------------------------------------------------------------
  # perform/1 — cache write failure (Issue #266)
  # ---------------------------------------------------------------------------

  describe "perform/1 — cache write failure" do
    test "returns {:error, _} so Oban retries when the cache write fails" do
      user = insert(:user, profile_visibility: "platform")
      _bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")

      changeset =
        %FeedCacheEntry{}
        |> Ecto.Changeset.change(%{})
        |> Ecto.Changeset.add_error(:bookshelf_id, "forced write failure")

      Application.put_env(:core, :feed_cache_writer, fn _id, _xml, _etag ->
        {:error, changeset}
      end)

      on_exit(fn -> Application.delete_env(:core, :feed_cache_writer) end)

      assert {:error, _reason} =
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
