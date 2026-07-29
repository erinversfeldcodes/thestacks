defmodule StacksWeb.FeedControllerTest do
  @moduledoc """
  Tests for GET /api/feeds/:user_id/:bookshelf_name.
  """

  # async: false — mutates the global :feed_cache_writer env seam (see FeedsTest).
  use CoreWeb.ConnCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.Guardian
  alias Stacks.Feeds.FeedCacheEntry

  # ⚠️ A `platform` bookshelf's feed now requires a signed-in reader (owner ruling 2026-07-29:
  # `platform` means "authenticated users only" on the Audience ladder, so serving it anonymously
  # contradicted the ladder). These tests are about caching, ETags and serving mechanics, so they
  # authenticate a viewer rather than downgrade their fixtures to `public` — keeping the platform
  # path covered at the controller layer, which is where the exposure actually happened.
  defp as_reader(conn) do
    {:ok, token, _} = Guardian.encode_and_sign(insert(:user))
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "GET /api/feeds/u/:handle/:bookshelf_name — the canonical, handle form" do
    test "serves the same feed as the id form", %{conn: conn} do
      # ⚠️ The form that made G4 buildable at all. Profiles are addressed by handle
      # everywhere (`/u/:handle`), so a page listing someone's bookshelves has their
      # handle and not their UUID — the client could not construct the id-form URL, which
      # is why no client call existed. The chain was broken at the contract.
      user = insert(:user, display_name: "Erin", handle: "erin")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "The Secret History")
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      by_handle = get(as_reader(conn), "/api/feeds/u/erin/library")

      assert by_handle.status == 200
      assert by_handle.resp_body =~ "The Secret History"

      assert get_resp_header(by_handle, "content-type") |> List.first() =~ "application/atom+xml"
    end

    test "404s for a handle nobody has", %{conn: conn} do
      conn = get(as_reader(conn), "/api/feeds/u/nobody-here/library")
      assert conn.status == 404
    end

    test "still 403s a non-platform bookshelf, same as the id form", %{conn: conn} do
      # The handle form must not become a way around the visibility rule.
      user = insert(:user, handle: "private-erin")
      _bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")

      conn = get(as_reader(conn), "/api/feeds/u/private-erin/library")
      assert conn.status == 403
    end

    test "\"u\" is not swallowed as a user id", %{conn: conn} do
      # Both routes are declared, and the handle one must win for `/feeds/u/...`.
      # If ordering regressed, this would try to resolve "u" as a UUID.
      conn = get(as_reader(conn), "/api/feeds/u/erin/library")
      refute conn.status == 500
    end
  end

  describe "GET /api/feeds/:user_id/:bookshelf_name" do
    test "returns 200 with Atom XML for a platform-visible bookshelf", %{conn: conn} do
      user = insert(:user, display_name: "Erin")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      author = insert(:author, name: "Donna Tartt")
      book = insert(:book, title: "The Secret History", author: author)
      _edition = insert(:book_edition, book: book, isbn: "9780140167771", is_primary: true)
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      conn = get(as_reader(conn), "/api/feeds/#{user.id}/library")

      assert conn.status == 200
      assert {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
      assert String.contains?(content_type, "application/atom+xml")
      assert {"etag", _etag} = List.keyfind(conn.resp_headers, "etag", 0)
      assert String.contains?(conn.resp_body, "<feed xmlns=")
      assert String.contains?(conn.resp_body, "The Secret History")
    end

    test "returns 304 Not Modified when ETag matches", %{conn: conn} do
      user = insert(:user, display_name: "Erin")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "Stable Book")
      fixed_time = ~U[2026-01-01 12:00:00.000000Z]
      _placement = insert(:placement, bookshelf: bookshelf, book: book, placed_at: fixed_time)

      # First request to get the ETag
      conn1 = get(as_reader(conn), "/api/feeds/#{user.id}/library")
      assert conn1.status == 200
      {"etag", etag} = List.keyfind(conn1.resp_headers, "etag", 0)

      # Second request with If-None-Match
      conn2 =
        build_conn()
        |> as_reader()
        |> put_req_header("if-none-match", etag)
        |> get("/api/feeds/#{user.id}/library")

      assert conn2.status == 304
    end

    test "returns 404 for nonexistent bookshelf", %{conn: conn} do
      conn = get(as_reader(conn), "/api/feeds/#{Ecto.UUID.generate()}/library")

      assert %{"error" => "Bookshelf not found"} = json_response(conn, 404)
    end

    test "returns 403 for a bookshelf the reader has not shared", %{conn: conn} do
      user = insert(:user)
      _bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")

      conn = get(as_reader(conn), "/api/feeds/#{user.id}/library")

      # The status is the contract; the sentence is copy. This asserted the exact phrase
      # "platform-visible", which broke the moment the message had to cover `public` too —
      # the same brittleness that let a SECURITY assertion elsewhere pass by matching nothing.
      assert %{"error" => error} = json_response(conn, 403)
      assert is_binary(error) and error != ""
    end

    test "serves the feed for a bookshelf shared MORE widely than platform", %{conn: conn} do
      # ⛔ Returned 403. The eligibility check was `visibility != "platform"` — an equality
      # test against one rung of the `owner < group < platform < public` ladder — so the most
      # shared tier was refused what a less shared one was granted.
      user = insert(:user)
      _bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "public")

      conn = get(as_reader(conn), "/api/feeds/#{user.id}/library")

      assert response(conn, 200)
      assert conn |> get_resp_header("content-type") |> hd() =~ "application/atom+xml"
    end
  end

  # ---------------------------------------------------------------------------
  # Cache read/write behaviour (Issue #264)
  # ---------------------------------------------------------------------------

  describe "GET /api/feeds — cache hit" do
    test "serves the STORED atom_xml + etag verbatim (not a fresh render)", %{conn: conn} do
      user = insert(:user, display_name: "Erin")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")

      # Seed a cache row whose body is deliberately distinct from anything a
      # fresh render would produce — proves the controller reads the store.
      stored_xml = ~s(<?xml version="1.0"?><feed xmlns="stored">SENTINEL-CACHED-BODY</feed>)
      stored_etag = Stacks.Feeds.compute_etag(stored_xml)

      Repo.insert!(%FeedCacheEntry{
        bookshelf_id: bookshelf.id,
        atom_xml: stored_xml,
        etag: stored_etag
      })

      conn = get(as_reader(conn), "/api/feeds/#{user.id}/library")

      assert conn.status == 200
      assert conn.resp_body == stored_xml
      assert {"etag", etag} = List.keyfind(conn.resp_headers, "etag", 0)
      assert etag == ~s("#{stored_etag}")

      {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
      assert String.contains?(content_type, "application/atom+xml")

      assert {"cache-control", "public, max-age=300"} =
               List.keyfind(conn.resp_headers, "cache-control", 0)
    end

    test "returns 304 when If-None-Match matches the STORED etag", %{conn: conn} do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")

      stored_xml = ~s(<feed xmlns="stored">CACHED</feed>)
      stored_etag = Stacks.Feeds.compute_etag(stored_xml)

      Repo.insert!(%FeedCacheEntry{
        bookshelf_id: bookshelf.id,
        atom_xml: stored_xml,
        etag: stored_etag
      })

      conn =
        conn
        |> as_reader()
        |> put_req_header("if-none-match", ~s("#{stored_etag}"))
        |> get("/api/feeds/#{user.id}/library")

      assert conn.status == 304
    end
  end

  describe "GET /api/feeds — cache miss fills the cache" do
    test "generates, writes the cache row, and serves the fresh feed", %{conn: conn} do
      user = insert(:user, display_name: "Erin")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "The Secret History")
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      # No cache row yet.
      assert Repo.aggregate(
               from(fc in FeedCacheEntry, where: fc.bookshelf_id == ^bookshelf.id),
               :count
             ) == 0

      conn = get(as_reader(conn), "/api/feeds/#{user.id}/library")

      assert conn.status == 200
      assert String.contains?(conn.resp_body, "The Secret History")

      # The miss must have FILLED the cache with exactly what it served.
      row = Repo.get_by(FeedCacheEntry, bookshelf_id: bookshelf.id)
      assert row, "a cache miss must persist a row"
      assert row.atom_xml == conn.resp_body
      {"etag", served_etag} = List.keyfind(conn.resp_headers, "etag", 0)
      assert served_etag == ~s("#{row.etag}")
    end
  end

  # ---------------------------------------------------------------------------
  # Cache-write failure must not 500 the public endpoint (Issue #266)
  # ---------------------------------------------------------------------------

  describe "GET /api/feeds — cache write failure" do
    test "still serves the fresh feed with a 200 (no 500) when the cache write fails",
         %{conn: conn} do
      user = insert(:user, display_name: "Erin")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "The Secret History")
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      # Force the cache miss-fill to fail via the injected writer seam.
      changeset =
        %FeedCacheEntry{}
        |> Ecto.Changeset.change(%{})
        |> Ecto.Changeset.add_error(:bookshelf_id, "forced write failure")

      Application.put_env(:core, :feed_cache_writer, fn _id, _xml, _etag ->
        {:error, changeset}
      end)

      on_exit(fn -> Application.delete_env(:core, :feed_cache_writer) end)

      conn = get(as_reader(conn), "/api/feeds/#{user.id}/library")

      assert conn.status == 200
      assert String.contains?(conn.resp_body, "The Secret History")
      assert {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
      assert String.contains?(content_type, "application/atom+xml")

      # The write failed, so no cache row was persisted — the render was served
      # directly, proving the cache is an optimization, not a hard dependency.
      assert Repo.aggregate(
               from(fc in FeedCacheEntry, where: fc.bookshelf_id == ^bookshelf.id),
               :count
             ) == 0
    end
  end
end
