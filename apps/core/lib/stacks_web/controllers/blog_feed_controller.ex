defmodule StacksWeb.BlogFeedController do
  @moduledoc """
      The writer's public blog feed — the URL they paste into
      Substack's *Settings → Import → RSS* once, after which every public post
      arrives there as a draft.

      ⛔ **Anonymous-only, and the missing `:optional_auth` is a security control,
      not an omission.** The shelf feed (`FeedController`) is `:optional_auth`
      because a `platform` bookshelf's feed is legitimately visible to a signed-in
      reader. THIS feed's consumer is a third-party fetcher that republishes what
      it reads, so the viewer is removed from the picture entirely: any token on
      the request is ignored, and there is no authenticated branch through which a
      non-public post could be served. Guarded by a test that fetches WITH a valid
      owner token and asserts the platform post is still absent.
  """

  use CoreWeb, :controller

  alias Stacks.Accounts
  alias Stacks.Blog.Syndication

  @doc "GET /api/feeds/u/:handle/blog — Atom 1.0, ETag, 5-minute cache."
  def show(conn, %{"handle" => handle}) do
    case Accounts.get_user_by_handle(handle) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{error: "Reader not found"})

      user ->
        {xml, etag} = Syndication.feed_xml(user)
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
    end
  end
end
