defmodule Stacks.FeedsTest do
  @moduledoc """
  Tests for Stacks.Feeds context — Atom feed generation for public bookshelves.
  """

  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Feeds
  alias Stacks.Feeds.FeedCacheEntry

  # A cache writer that always fails, mirroring the `{:error, changeset}` shape
  # `put_cache/3` returns on a real FK/constraint violation. Injected via the
  # `:feed_cache_writer` application env seam.
  defp failing_writer do
    changeset =
      %FeedCacheEntry{}
      |> Ecto.Changeset.change(%{})
      |> Ecto.Changeset.add_error(:bookshelf_id, "forced write failure")

    fn _bookshelf_id, _xml, _etag -> {:error, changeset} end
  end

  defp inject_failing_writer do
    Application.put_env(:core, :feed_cache_writer, failing_writer())
    on_exit(fn -> Application.delete_env(:core, :feed_cache_writer) end)
  end

  describe "fetch_feed/2" do
    test "returns {:ok, xml, etag} for a platform-visible bookshelf" do
      user = insert(:user, display_name: "Erin")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      author = insert(:author, name: "Donna Tartt")
      book = insert(:book, title: "The Secret History", author: author)
      _edition = insert(:book_edition, book: book, isbn: "9780140167771", is_primary: true)
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, xml, etag} = Feeds.fetch_feed(user.id, "library")

      assert is_binary(xml)
      assert is_binary(etag)
      assert String.contains?(xml, "Erin")
      assert String.contains?(xml, "The Secret History")
      assert String.contains?(xml, "Donna Tartt")
      assert String.contains?(xml, "9780140167771")
      assert String.contains?(xml, "application/atom+xml") == false
      assert String.contains?(xml, "<feed xmlns=")
      assert String.contains?(xml, "<entry>")
    end

    test "returns {:error, :not_found} for nonexistent bookshelf" do
      assert {:error, :not_found} = Feeds.fetch_feed(Ecto.UUID.generate(), "library")
    end

    test "returns {:error, :not_public} for owner-visibility bookshelf" do
      user = insert(:user)
      _bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")

      assert {:error, :not_public} = Feeds.fetch_feed(user.id, "library")
    end

    test "returns {:error, :not_public} for group-visibility bookshelf" do
      user = insert(:user)
      _bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "group")

      assert {:error, :not_public} = Feeds.fetch_feed(user.id, "library")
    end

    test "returns valid XML with empty bookshelf" do
      user = insert(:user, display_name: "Test User")
      _bookshelf = insert(:bookshelf, user: user, name: "wishlist", visibility: "platform")

      assert {:ok, xml, _etag} = Feeds.fetch_feed(user.id, "wishlist")
      assert String.contains?(xml, "<feed xmlns=")
      assert String.contains?(xml, "Test User")
      refute String.contains?(xml, "<entry>")
    end

    test "escapes XML special characters in titles" do
      user = insert(:user, display_name: "A & B <User>")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "Tom & Jerry <Adventures>")
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, xml, _etag} = Feeds.fetch_feed(user.id, "library")
      assert String.contains?(xml, "&amp;")
      assert String.contains?(xml, "&lt;")
    end

    test "a cache-write failure still serves the fresh render (cache is an optimization)" do
      user = insert(:user, display_name: "Erin")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "The Secret History")
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      inject_failing_writer()

      assert {:ok, xml, etag} = Feeds.fetch_feed(user.id, "library")
      assert String.contains?(xml, "The Secret History")
      assert is_binary(etag)

      # The write failed, so no row was persisted — proving the render was
      # served despite the cache miss-fill failing.
      assert [] = Repo.all(from fc in FeedCacheEntry, where: fc.bookshelf_id == ^bookshelf.id)
    end
  end

  describe "regenerate/2" do
    test "returns {:ok, xml, etag} and upserts the cache row for a platform bookshelf" do
      user = insert(:user, display_name: "Erin")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "The Secret History")
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, xml, etag} = Feeds.regenerate(user.id, "library")
      assert String.contains?(xml, "The Secret History")

      row = Repo.get_by(FeedCacheEntry, bookshelf_id: bookshelf.id)
      assert row
      assert row.atom_xml == xml
      assert row.etag == etag
    end

    test "returns {:error, :not_found} for a nonexistent bookshelf" do
      assert {:error, :not_found} = Feeds.regenerate(Ecto.UUID.generate(), "library")
    end

    test "returns {:error, :not_public} for an owner-visibility bookshelf" do
      user = insert(:user)
      _bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")

      assert {:error, :not_public} = Feeds.regenerate(user.id, "library")
    end

    test "surfaces {:error, {:cache_write_failed, changeset}} when the cache write fails" do
      user = insert(:user)
      _bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")

      inject_failing_writer()

      assert {:error, {:cache_write_failed, %Ecto.Changeset{}}} =
               Feeds.regenerate(user.id, "library")
    end
  end

  describe "put_cache/3" do
    test "returns {:error, %Ecto.Changeset{}} on an FK violation rather than raising" do
      # A bookshelf_id with no matching op.bookshelves row violates the FK.
      # The changeset must translate that into an error tuple, not a raise.
      assert {:error, %Ecto.Changeset{} = changeset} =
               Feeds.put_cache(Ecto.UUID.generate(), "<feed/>", "etag")

      refute changeset.valid?
    end
  end

  describe "compute_etag/1" do
    test "returns consistent MD5 hash for same content" do
      xml = "<feed>test</feed>"
      etag1 = Feeds.compute_etag(xml)
      etag2 = Feeds.compute_etag(xml)
      assert etag1 == etag2
      assert String.length(etag1) == 32
    end

    test "returns different hash for different content" do
      etag1 = Feeds.compute_etag("<feed>one</feed>")
      etag2 = Feeds.compute_etag("<feed>two</feed>")
      refute etag1 == etag2
    end
  end

  describe "op.feed_cache schema" do
    test "has exactly one index on bookshelf_id (the unique index; no redundant FK index)" do
      %{rows: rows} =
        Repo.query!(
          """
          SELECT indexname
          FROM pg_indexes
          WHERE schemaname = 'op'
            AND tablename = 'feed_cache'
            AND indexdef ILIKE '%(bookshelf_id)%'
          ORDER BY indexname
          """,
          []
        )

      names = List.flatten(rows)
      assert names == ["feed_cache_bookshelf_id_unique_index"]
    end
  end
end
