defmodule CoreWeb.PageController do
  use CoreWeb, :controller

  def index(conn, _params) do
    index_path = Application.app_dir(:core, ["priv", "static", "index.html"])

    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> send_file(200, index_path)
  end

  @doc """
  Permanent-feel redirect for the folded-away consent page (#318 TR-4).

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
