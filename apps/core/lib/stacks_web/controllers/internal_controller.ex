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
  alias Stacks.Proto.Vision.AssociateCallback

  @path "/api/internal/vision/associate"
  @replay_window_seconds 60

  # Proto AssociationStatus enum wire-format strings.
  # These MUST match the JSON names in stacks/internal/v1/vision.proto.
  # See docs/runbooks/vision-service-rollback.md for deploy ordering.
  @status_confirmed "ASSOCIATION_STATUS_CONFIRMED"
  @status_rejected "ASSOCIATION_STATUS_REJECTED"

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

  # Decode the raw JSON params into a typed AssociateCallback struct, then dispatch.
  # Required fields default to "" for validation; optional `reason` defaults to nil
  # (consistent with the proto3 optional field default).
  defp handle_association(conn, params) do
    callback = %AssociateCallback{
      isbn: Map.get(params, "isbn", ""),
      book_id: Map.get(params, "book_id", ""),
      edition_id: Map.get(params, "edition_id", ""),
      status: Map.get(params, "status", ""),
      job_id: Map.get(params, "job_id", ""),
      reason: Map.get(params, "reason"),
      cover_image_url: Map.get(params, "cover_image_url", "")
    }

    case validate_callback(callback) do
      :ok ->
        dispatch_association(conn, callback)

      {:error, reason} ->
        Logger.warning("InternalController: invalid callback payload — #{reason}")
        json(conn, %{ok: true})
    end
  end

  defp validate_callback(%AssociateCallback{isbn: ""}),
    do: {:error, "isbn is required"}

  defp validate_callback(%AssociateCallback{job_id: ""}),
    do: {:error, "job_id is required"}

  defp validate_callback(%AssociateCallback{edition_id: ""}),
    do: {:error, "edition_id is required"}

  defp validate_callback(%AssociateCallback{status: ""}),
    do: {:error, "status is required"}

  defp validate_callback(%AssociateCallback{
         status: @status_confirmed,
         cover_image_url: ""
       }),
       do: {:error, "cover_image_url is required for confirmed status"}

  defp validate_callback(%AssociateCallback{
         status: @status_confirmed,
         cover_image_url: url
       })
       when is_binary(url) and byte_size(url) > 0 do
    if String.starts_with?(url, "http://") or String.starts_with?(url, "https://") do
      :ok
    else
      {:error, "cover_image_url must use http or https scheme"}
    end
  end

  defp validate_callback(_callback), do: :ok

  defp dispatch_association(conn, %AssociateCallback{
         status: @status_confirmed,
         edition_id: edition_id,
         cover_image_url: cover_url
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

  defp dispatch_association(conn, %AssociateCallback{
         status: @status_rejected,
         edition_id: edition_id,
         reason: reason
       }) do
    reason_suffix = if is_binary(reason) and reason != "", do: ": #{reason}", else: ""

    Logger.warning(
      "InternalController: cover association rejected for edition #{edition_id}#{reason_suffix}"
    )

    json(conn, %{ok: true})
  end

  defp dispatch_association(conn, %AssociateCallback{status: status}) do
    Logger.warning("InternalController: unknown status #{inspect(status)} received")

    :telemetry.execute(
      [:stacks, :vision, :unknown_association_status],
      %{count: 1},
      %{status: status}
    )

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
    # The vision sidecar must sign the string: "<ts>.POST./api/internal/vision/associate"
    # using HMAC-SHA256 with the shared VISION_HMAC_SECRET.
    with {ts, ""} <- Integer.parse(ts_str),
         now = System.os_time(:second),
         true <- abs(now - ts) <= @replay_window_seconds,
         secret when not is_nil(secret) <-
           Application.get_env(:core, :vision_hmac_secret) do
      message = "#{ts_str}.POST.#{@path}"
      expected = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)
      Plug.Crypto.secure_compare(expected, provided_sig)
    else
      :error ->
        Logger.warning("InternalController: X-Vision-Signature has non-numeric timestamp")
        false

      false ->
        Logger.warning(
          "InternalController: X-Vision-Signature timestamp outside ±60s replay window"
        )

        false

      nil ->
        Logger.error("InternalController: vision_hmac_secret not configured — rejecting request")
        false
    end
  end
end
