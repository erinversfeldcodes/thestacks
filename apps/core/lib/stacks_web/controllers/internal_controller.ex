defmodule StacksWeb.InternalController do
  @moduledoc """
  Handles internal callbacks from the vision sidecar service.

  Protected by a timestamp-based HMAC scheme via the X-Vision-Signature header:
    Value: "<unix_timestamp_seconds>.<HMAC-SHA256(secret, "<ts>.POST.<path>")>" (lowercase hex)
    Valid window: ±60 seconds

  No user authentication — service-to-service only.
  Always returns 200 to the vision sidecar once auth passes (sidecar must not retry on app errors).
  """

  use CoreWeb, :controller

  require Logger

  alias Stacks.Books

  @path "/api/internal/vision/associate"
  @replay_window_seconds 60

  @doc "POST /api/internal/vision/associate — receive async cover association result."
  def vision_associate(conn, params) do
    if valid_signature?(conn) do
      handle_association(conn, params)
    else
      conn
      |> put_status(401)
      |> json(%{error: "unauthorized"})
    end
  end

  defp handle_association(conn, %{
         "status" => "confirmed",
         "edition_id" => edition_id,
         "cover_url" => cover_url
       }) do
    case Books.confirm_cover_association(edition_id, cover_url) do
      {:ok, _edition} ->
        json(conn, %{ok: true})

      {:error, :not_found} ->
        Logger.warning(
          "InternalController: edition #{edition_id} not found for cover confirmation"
        )

        json(conn, %{ok: true})

      {:error, reason} ->
        Logger.error(
          "InternalController: failed to confirm cover for edition #{edition_id}: #{inspect(reason)}"
        )

        json(conn, %{ok: true})
    end
  end

  defp handle_association(conn, %{"status" => "rejected", "edition_id" => edition_id}) do
    Logger.warning("InternalController: cover association rejected for edition #{edition_id}")
    json(conn, %{ok: true})
  end

  defp handle_association(conn, %{"status" => status}) do
    Logger.warning("InternalController: unknown status #{inspect(status)} received")
    json(conn, %{ok: true})
  end

  defp handle_association(conn, _params) do
    Logger.warning("InternalController: malformed payload received")
    json(conn, %{ok: true})
  end

  defp valid_signature?(conn) do
    case get_req_header(conn, "x-vision-signature") do
      [provided] -> verify_token(provided)
      _ -> false
    end
  end

  defp verify_token(provided) do
    case String.split(provided, ".", parts: 2) do
      [ts_str, provided_sig] -> verify_hmac(ts_str, provided_sig)
      _ -> false
    end
  end

  defp verify_hmac(ts_str, provided_sig) do
    with {ts, ""} <- Integer.parse(ts_str),
         now = System.os_time(:second),
         true <- abs(now - ts) <= @replay_window_seconds do
      secret = Application.fetch_env!(:core, :vision_hmac_secret)
      message = "#{ts_str}.POST.#{@path}"
      expected = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)
      Plug.Crypto.secure_compare(expected, provided_sig)
    else
      _ -> false
    end
  end
end
