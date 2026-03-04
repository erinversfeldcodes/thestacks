defmodule CoreWeb.HealthController do
  use CoreWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok", service: "core"})
  end
end
