defmodule StacksWeb.FeedController do
  @moduledoc """
  Public controller for Atom feed generation per bookshelf.

  Serves Atom 1.0 XML with proper content type, ETag caching,
  and 304 Not Modified support.
  """

  use CoreWeb, :controller

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian
  alias Stacks.Feeds

  @doc """
  GET /api/feeds/u/:handle/:bookshelf_name — serves Atom XML for a public bookshelf.

  The handle form is canonical; `/api/feeds/:user_id/:bookshelf_name` still resolves for
  anything holding a direct link.

  Serves the persisted `op.feed_cache` row on a hit; on a miss it generates the
  feed, fills the cache, and serves the fresh result (`Feeds.fetch_feed/2`).

  Sets `Content-Type: application/atom+xml` and includes an ETag header.
  Returns 304 Not Modified if the client sends a matching `If-None-Match` header.
  Returns 404 if the bookshelf does not exist.
  Returns 403 if the bookshelf is not platform-visible.
  """
  def show(conn, %{"handle" => handle, "bookshelf_name" => bookshelf_name}) do
    # Handle-addressed, and this is the clause the SPA uses.
    #
    # ⚠️ The reason G4 had no client call was not that nobody wrote one: profiles are
    # addressed by **handle** everywhere (`/u/:handle`, `GET /api/u/:handle`), while this
    # controller was keyed only by **user_id**. A page showing someone's bookshelves has
    # their handle and not their UUID, so it could not construct a feed URL at all — the
    # chain was broken at the *contract*, one layer below the missing call.
    #
    # It is also the better URL to hand a person: `/api/feeds/u/erin/library` is legible
    # and checkable, where a UUID is neither.
    case Accounts.get_user_by_handle(handle) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{error: "Reader not found"})

      user ->
        show(conn, %{"user_id" => user.id, "bookshelf_name" => bookshelf_name})
    end
  end

  def show(conn, %{"user_id" => user_id, "bookshelf_name" => bookshelf_name}) do
    # `:optional_auth` populates this when a token is present, and leaves it nil otherwise. A
    # `platform` bookshelf's feed needs a viewer; a `public` one does not (owner decision
    # 2026-07-29). Passed explicitly rather than defaulted, so "anonymous" is never implicit.
    viewer = Guardian.Plug.current_resource(conn)

    case Feeds.fetch_feed(user_id, bookshelf_name, viewer) do
      {:ok, xml, etag} ->
        client_etag = get_req_header(conn, "if-none-match") |> List.first()

        if client_etag == "\"#{etag}\"" do
          conn
          |> put_resp_header("etag", "\"#{etag}\"")
          |> send_resp(304, "")
        else
          conn
          |> put_resp_content_type("application/atom+xml")
          |> put_resp_header("etag", "\"#{etag}\"")
          |> put_resp_header("cache-control", "public, max-age=300")
          |> send_resp(200, xml)
        end

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Bookshelf not found"})

      {:error, :not_public} ->
        conn
        |> put_status(403)
        |> json(%{error: "Feed is only available for bookshelves shared with the platform"})
    end
  end
end
