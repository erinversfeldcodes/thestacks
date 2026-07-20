defmodule StacksWeb.FeedController do
  @moduledoc """
  Public controller for Atom feed generation per bookshelf.

  Serves Atom 1.0 XML with proper content type, ETag caching,
  and 304 Not Modified support.
  """

  use CoreWeb, :controller

  alias Stacks.Feeds

  @doc """
  GET /api/feeds/:user_id/:bookshelf_name — serves Atom XML for a public bookshelf.

  Serves the persisted `op.feed_cache` row on a hit; on a miss it generates the
  feed, fills the cache, and serves the fresh result (`Feeds.fetch_feed/2`).

  Sets `Content-Type: application/atom+xml` and includes an ETag header.
  Returns 304 Not Modified if the client sends a matching `If-None-Match` header.
  Returns 404 if the bookshelf does not exist.
  Returns 403 if the bookshelf is not platform-visible.
  """
  def show(conn, %{"user_id" => user_id, "bookshelf_name" => bookshelf_name}) do
    case Feeds.fetch_feed(user_id, bookshelf_name) do
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
        |> json(%{error: "Feed is only available for platform-visible bookshelves"})
    end
  end
end
