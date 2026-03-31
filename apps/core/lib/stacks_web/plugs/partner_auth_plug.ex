defmodule StacksWeb.PartnerAuthPlug do
  @moduledoc """
  Authenticates partner API requests via `Authorization: Bearer sk_partner_...` header.
  Sets `conn.assigns[:current_partner]` on success. Halts with 401 on failure.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Stacks.Partners

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw_key] ->
        case Partners.authenticate_partner(raw_key) do
          {:ok, partner} -> assign(conn, :current_partner, partner)
          {:error, :invalid} -> unauthorized(conn)
        end

      _ ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(401)
    |> json(%{error: "Invalid or missing partner API key"})
    |> halt()
  end
end
