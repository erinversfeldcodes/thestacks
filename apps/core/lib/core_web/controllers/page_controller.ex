defmodule CoreWeb.PageController do
  use CoreWeb, :controller

  def index(conn, _params) do
    index_path = Application.app_dir(:core, ["priv", "static", "index.html"])

    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> send_file(200, index_path)
  end
end
