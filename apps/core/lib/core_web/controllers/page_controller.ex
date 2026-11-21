defmodule CoreWeb.PageController do
  use CoreWeb, :controller

  alias Stacks.Accounts
  alias Stacks.Accounts.User

  def index(conn, params) do
    index_path = Application.app_dir(:core, ["priv", "static", "index.html"])

    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> put_robots_directive(params)
    |> send_file(200, index_path)
  end

  # The per-resource crawl directive, FAIL-CLOSED: every SPA shell response is
  # `noindex` unless it is EXACTLY a reader's PUBLIC profile page AND that reader
  # opted in to search indexing (the per-user opt-in). A missing handle, a
  # non-public profile, no opt-in, OR any deeper path under the handle all fall
  # through to noindex — the global default this header replaces.
  #
  # ⛔ Matches `["u", handle]` EXACTLY, not `["u", handle | _]`: a deeper path
  # such as `/u/mara/bookshelves/<a-platform-only-shelf>` is a sub-resource whose
  # own visibility this directive does not resolve, so it must not inherit the
  # profile's `index`. The opt-in indexes the PROFILE; indexing an individual
  # public sub-resource (a public shelf) is a separate, finer-grained decision
  # and stays noindex until it is designed.
  defp put_robots_directive(conn, params) do
    put_resp_header(conn, "x-robots-tag", robots_directive(params))
  end

  defp robots_directive(%{"path" => ["u", handle]}) when is_binary(handle) do
    if indexable_profile?(handle), do: "index, follow", else: "noindex, nofollow"
  end

  defp robots_directive(_params), do: "noindex, nofollow"

  # Reads the opt-in off the row `get_user_by_handle/1` already loaded — no second
  # query on this hot, most-crawled public route.
  defp indexable_profile?(handle) do
    case Accounts.get_user_by_handle(handle) do
      %User{profile_visibility: "public", consent_search_indexing: true} -> true
      _ -> false
    end
  end

  @doc """
      404 JSON for any unmatched request under `/api`.

      The SPA catch-all answers `200 text/html` for every path the router does
      not recognise, which is right for a client-side route and wrong for an API
      path: a mistyped, removed or wrong-method endpoint came back as the
      application shell with a 200, so `Api.isNotFound` was structurally unable
      to fire for it and a decoder saw HTML instead of an error. The symptom that
      found this: moving the invitation lookup off its old URL left that URL
      answering 200 — with the live code still in `conn.request_path`, and now
      with nothing anomalous in the status to notice it by.
  """
  def api_not_found(conn, _params) do
    conn
    |> put_status(:not_found)
    |> Phoenix.Controller.json(%{error: "not_found"})
  end

  @doc """
      Permanent-feel redirect for the folded-away consent page (TR-4).

      `/settings/consent` no longer exists as its own page — the consent controls
      moved into `/settings/privacy`. Existing links and bookmarks are kept working
      by 302-redirecting to Privacy. This is a UI/IA fold only; nothing about what
      `Stacks.GDPR.Consent` records or the `POST /api/gdpr/consent` write path
      changes.
  """
  def redirect_consent(conn, _params) do
    redirect(conn, to: "/settings/privacy")
  end
end
