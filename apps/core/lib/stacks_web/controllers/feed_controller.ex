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

      # ⚠️ 403 HERE, AND 404 ON THE GROUP FEED — the difference is deliberate and
      # keeps being re-found as a defect, so here is why it is not one.
      #
      # Four places in this codebase state a "404, not 403" rule, because a 403
      # confirms a resource exists to a caller not entitled to know that. It is a
      # real rule and the group feed follows it: an invite-only group's EXISTENCE
      # is confidential, so a stranger gets 404.
      #
      # A bookshelf's existence is not. Every reader has all five of the named
      # bookshelves from registration — measured: five distinct names, five
      # shelves per user — and handles are public, appearing in profile URLs. So
      # `GET /api/feeds/u/alice/wishlist` answering 403 rather than 404 discloses
      # nothing beyond "the handle alice exists", which the profile page already
      # says. What 403 buys instead is an honest answer to the owner and to a
      # feed reader: the shelf is there and is not shared with the platform,
      # which is actionable, where 404 would send them looking for a typo.
      #
      # ⛔ So the rule is conditional on confidentiality of EXISTENCE, not
      # universal. If bookshelves ever become optional or renameable, this
      # branch becomes a leak and should move to 404.
      {:error, :not_public} ->
        conn
        |> put_status(403)
        |> json(%{error: "Feed is only available for bookshelves shared with the platform"})
    end
  end
end
