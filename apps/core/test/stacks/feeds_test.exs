defmodule Stacks.FeedsTest do
  @moduledoc """
  Tests for Stacks.Feeds context — Atom feed generation for public bookshelves.
  """

  # async: false — these tests swap the GLOBAL :feed_cache_writer application-env
  # seam (Application.put_env); running async lets the override leak into (and be
  # reset under) concurrent tests that exercise the cache write path.
  use Core.DataCase, async: false

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

      book =
        insert(:book,
          title: "The Secret History",
          author: author,
          editions: [build(:primary_book_edition, isbn: "9780140167771")]
        )

      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, xml, etag} = Feeds.fetch_feed(user.id, "library", user)

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

      assert {:error, :not_public} = Feeds.fetch_feed(user.id, "library", user)
    end

    test "returns {:error, :not_public} for group-visibility bookshelf" do
      user = insert(:user)
      _bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "group")

      assert {:error, :not_public} = Feeds.fetch_feed(user.id, "library", user)
    end

    test "serves a feed for a public-visibility bookshelf" do
      # ⛔ It did not. `resolve_platform_bookshelf/2` tested `visibility != "platform"`, an
      # equality check where the ladder needs a comparison — so a bookshelf on the **most**
      # shared tier (`public`) was refused its feed with `:not_public` while the *less* shared
      # `platform` was served one. Exposure and function ran in opposite directions.
      #
      # The atom name is what hid it: `{:error, :not_public}` returned for the literally public
      # case reads as correct in every call site and in both existing rejection tests above,
      # which only ever covered `owner` and `group`. `public` was never tested.
      #
      # `Stacks.Visibility.audience_levels/0` is `owner < group < platform < public`, and
      # `@valid_visibilities` is that whole list — so `public` is a reachable state for any
      # bookshelf, not a hypothetical.
      user = insert(:user, display_name: "Ada")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "public")
      author = insert(:author, name: "Donna Tartt")

      book =
        insert(:book,
          title: "The Secret History",
          author: author,
          editions: [build(:primary_book_edition, isbn: "9780140167771")]
        )

      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, xml, etag} = Feeds.fetch_feed(user.id, "library", user),
             "a bookshelf the reader marked public is refused the feed a platform one gets"

      assert is_binary(etag)
      assert String.contains?(xml, "The Secret History")
    end

    test "a PLATFORM bookshelf's feed is not served to an anonymous reader" do
      # ⚠️ Owner ruling 2026-07-29: `platform` means "any authenticated platform user — NOT visible
      # to logged-out" on the Audience ladder, so serving it anonymously contradicted the ladder the
      # rest of the system enforces. The feed route sat in a wholly unauthenticated pipeline and
      # handed a reader's shelf — titles, authors — to any anonymous client.
      #
      # `:not_found` rather than a forbidden-style error is deliberate and matches
      # `GET /api/u/:handle` for a platform profile (#225): the ladder says the resource is
      # *invisible*, and "exists but not for you" would leak that the shelf exists.
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      _placement = insert(:placement, bookshelf: bookshelf, book: insert(:book))

      assert {:error, :not_found} = Feeds.fetch_feed(user.id, "library", nil)
    end

    test "a PUBLIC bookshelf's feed IS served to an anonymous reader" do
      # The other half of the same ruling, and the reason this is not simply "feeds need auth":
      # `public` means "anyone with the link, signed in or not". A feed reader has no session, so
      # requiring auth for `public` would make the feature pointless.
      user = insert(:user, display_name: "Ada")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "public")
      book = insert(:book, title: "The Secret History")
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, xml, _etag} = Feeds.fetch_feed(user.id, "library", nil),
             "a public bookshelf must be readable by an unauthenticated feed reader"

      assert String.contains?(xml, "The Secret History")
    end

    test "a signed-in reader may read a PLATFORM bookshelf's feed" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      _placement = insert(:placement, bookshelf: bookshelf, book: insert(:book))
      viewer = insert(:user)

      assert {:ok, _xml, _etag} = Feeds.fetch_feed(user.id, "library", viewer)
    end

    test "returns valid XML with empty bookshelf" do
      user = insert(:user, display_name: "Test User")
      _bookshelf = insert(:bookshelf, user: user, name: "wishlist", visibility: "platform")

      assert {:ok, xml, _etag} = Feeds.fetch_feed(user.id, "wishlist", user)
      assert String.contains?(xml, "<feed xmlns=")
      assert String.contains?(xml, "Test User")
      refute String.contains?(xml, "<entry>")
    end

    test "escapes XML special characters in titles" do
      user = insert(:user, display_name: "A & B <User>")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "Tom & Jerry <Adventures>")
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, xml, _etag} = Feeds.fetch_feed(user.id, "library", user)
      assert String.contains?(xml, "&amp;")
      assert String.contains?(xml, "&lt;")
    end

    # A public Atom document is crawled and cached by RSS readers, so the owner's
    # email must never appear anywhere in it (title/author/entries). These three
    # tests pin the fallback ladder: display_name → handle → neutral label.
    test "never leaks the owner email in feed XML when display_name and handle are blank (#283)" do
      # op.users.handle is NOT NULL (backfilled + app-assigned on every insert),
      # so the only reachable "no name" shape is a blank handle — the defensive
      # backstop the neutral label exists for.
      user =
        insert(:user,
          email: "owner-secret@example.com",
          display_name: nil,
          handle: ""
        )

      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "The Secret History")
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, xml, _etag} = Feeds.fetch_feed(user.id, "library", user)

      refute String.contains?(xml, "owner-secret@example.com")
      refute String.contains?(xml, "@")
      assert String.contains?(xml, "A Stacks reader")
    end

    test "falls back to the claimed handle when display_name is nil (#283)" do
      user =
        insert(:user,
          email: "owner-secret@example.com",
          display_name: nil,
          handle: "shadow_reader"
        )

      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "The Secret History")
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, xml, _etag} = Feeds.fetch_feed(user.id, "library", user)

      assert String.contains?(xml, "shadow_reader")
      refute String.contains?(xml, "owner-secret@example.com")
      refute String.contains?(xml, "@")
    end

    test "uses display_name when present and never the email (#283)" do
      user =
        insert(:user,
          email: "owner-secret@example.com",
          display_name: "Erin",
          handle: "shadow_reader"
        )

      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "The Secret History")
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, xml, _etag} = Feeds.fetch_feed(user.id, "library", user)

      assert String.contains?(xml, "Erin")
      refute String.contains?(xml, "owner-secret@example.com")
      refute String.contains?(xml, "@")
    end

    test "a cache-write failure still serves the fresh render (cache is an optimization)" do
      user = insert(:user, display_name: "Erin")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "The Secret History")
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      inject_failing_writer()

      assert {:ok, xml, etag} = Feeds.fetch_feed(user.id, "library", user)
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

    test "persists email-free cache XML for a nil-display-name user (#283 self-heal)" do
      # The migration busts pre-fix rows; regeneration must then refill the cache
      # with email-free XML so a subsequent hit never re-serves the email.
      user =
        insert(:user,
          email: "owner-secret@example.com",
          display_name: nil,
          handle: "shadow_reader"
        )

      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "The Secret History")
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, _xml, _etag} = Feeds.regenerate(user.id, "library")

      row = Repo.get_by(FeedCacheEntry, bookshelf_id: bookshelf.id)
      assert row
      refute String.contains?(row.atom_xml, "owner-secret@example.com")
      refute String.contains?(row.atom_xml, "@")
      assert String.contains?(row.atom_xml, "shadow_reader")
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

  describe "US-6.1 entry content" do
    setup do
      user = insert(:user)
      library = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      %{user: user, library: library}
    end

    defp place(bookshelf, book, opts \\ []) do
      insert(:placement, Keyword.merge([bookshelf: bookshelf, book: book], opts))
    end

    test "carries the cover as an enclosure", %{user: user, library: library} do
      # US-6.1 asks each entry to carry a cover thumbnail. It is what makes a feed
      # browsable in a reader rather than a list of sentences.
      book =
        insert(:book,
          editions: [
            build(:primary_book_edition,
              cover_image_url: "https://covers.openlibrary.org/b/id/99-M.jpg"
            )
          ]
        )

      place(library, book)

      {:ok, xml, _etag} = Feeds.regenerate(user.id, "library")

      assert xml =~ ~s(rel="enclosure")
      assert xml =~ "covers.openlibrary.org/b/id/99-M.jpg"
    end

    test "omits the enclosure rather than emitting an empty one", %{user: user, library: library} do
      # Most seeded editions have no cover: 200 of 201 measured. An empty href would be
      # invalid Atom and would render as a broken image in a reader.
      book = insert(:book, editions: [build(:primary_book_edition, cover_image_url: nil)])
      place(library, book)

      {:ok, xml, _etag} = Feeds.regenerate(user.id, "library")

      refute xml =~ ~s(rel="enclosure")
    end

    test "says 'moved' for a book that arrived from another shelf", %{
      user: user,
      library: library
    } do
      # US-6.1 names two verbs: "Erin moved The Secret History to Library" **or**
      # "Erin added Piranesi to the Reading Pile". Every entry used to say "added", so a
      # move — the more interesting signal, and the one a follower wants — read as an
      # acquisition.
      antilibrary = insert(:bookshelf, user: user, name: "antilibrary", visibility: "owner")
      book = insert(:book, title: "The Secret History")
      place(library, book)

      insert(:placement_history,
        book_id: book.id,
        from_bookshelf: antilibrary.id,
        to_bookshelf: library.id
      )

      {:ok, xml, _etag} = Feeds.regenerate(user.id, "library")

      assert xml =~ "The Secret History"
      assert xml =~ "moved to Library"
      refute xml =~ "added to Library"
    end

    test "says 'added' for a book with no move history", %{user: user, library: library} do
      book = insert(:book, title: "Piranesi")
      place(library, book)

      {:ok, xml, _etag} = Feeds.regenerate(user.id, "library")

      assert xml =~ "added to Library"
      refute xml =~ "moved to Library"
    end

    test "a move onto a *different* shelf does not make this one say moved",
         %{user: user, library: library} do
      # The history row must be scoped to this bookshelf. Without that scoping any book
      # that had ever moved anywhere would read as "moved" on every shelf it sits on.
      other = insert(:bookshelf, user: user, name: "reading_pile", visibility: "owner")
      third = insert(:bookshelf, user: user, name: "wishlist", visibility: "owner")
      book = insert(:book)
      place(library, book)

      insert(:placement_history,
        book_id: book.id,
        from_bookshelf: third.id,
        to_bookshelf: other.id
      )

      {:ok, xml, _etag} = Feeds.regenerate(user.id, "library")

      assert xml =~ "added to Library"
      refute xml =~ "moved to Library"
    end
  end
end
