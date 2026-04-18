defmodule StacksWeb.UploadController do
  @moduledoc "Handles image uploads and enqueues identification jobs."

  use CoreWeb, :controller

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Accounts.Guardian
  alias Stacks.Books
  alias Stacks.Books.UploadedImage
  alias Stacks.Shelving
  alias StacksWeb.ProtoJSON

  @doc """
  POST /api/upload/identify — synchronously identifies candidate books from an image.

  Accepts a JSON body with either `image_b64` (base64-encoded image bytes) or
  `image_url` (publicly accessible image URL). Calls the vision client inline and
  returns a list of candidate maps immediately — no Oban job is enqueued.

  Returns 200 `{status: "identified", candidates: [...]}` on success.
  Returns 422 when neither `image_b64` nor `image_url` is provided.
  """
  @spec identify(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def identify(conn, %{"image_b64" => image_b64}) when is_binary(image_b64) do
    user = Guardian.Plug.current_resource(conn)
    run_identify(conn, user.id, {:b64, image_b64})
  end

  def identify(conn, %{"image_url" => image_url}) when is_binary(image_url) do
    user = Guardian.Plug.current_resource(conn)
    run_identify(conn, user.id, {:url, image_url})
  end

  def identify(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "image_b64 or image_url is required"})
  end

  defp run_identify(conn, user_id, image_input) do
    case Books.identify(user_id, image_input) do
      {:ok, candidates} ->
        json(conn, %{status: "identified", candidates: candidates})

      {:error, _reason} ->
        conn
        |> put_status(500)
        |> json(%{error: "identification_failed"})
    end
  end

  @doc "POST /api/upload — accepts a multipart image upload and enqueues IdentifyBookJob."
  def create(conn, %{"image" => %Plug.Upload{} = upload}) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, image} <- Books.store_upload(user.id, upload),
         {:ok, _job} <- Books.upload_and_identify(user.id, image.id, image.storage_path) do
      conn
      |> put_status(202)
      |> json(%{status: "accepted", image_id: image.id})
    else
      {:error, _reason} ->
        conn
        |> put_status(500)
        |> json(%{error: "upload_failed"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "no image provided"})
  end

  @doc "GET /api/upload/:image_id/stream — stream SSE status updates for an uploaded image."
  @spec stream(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stream(conn, %{"image_id" => image_id}) do
    case Ecto.UUID.cast(image_id) do
      {:ok, uuid} -> render_stream(conn, uuid)
      :error -> conn |> put_status(400) |> json(%{error: "invalid image_id"})
    end
  end

  defp render_stream(conn, image_id) do
    user = Guardian.Plug.current_resource(conn)

    # Subscribe to PubSub BEFORE reading DB status to avoid race condition
    Phoenix.PubSub.subscribe(Core.PubSub, "upload:#{image_id}")

    result =
      from(i in UploadedImage,
        where: i.id == ^image_id,
        select: %{
          status: i.status,
          book_id: i.book_id,
          book_ids: i.book_ids,
          rejection_reason: i.rejection_reason,
          user_id: i.user_id
        }
      )
      |> Repo.one()

    case result do
      nil ->
        Phoenix.PubSub.unsubscribe(Core.PubSub, "upload:#{image_id}")
        conn |> put_status(404) |> json(%{error: "not found"})

      %{user_id: owner_id} when not is_nil(owner_id) and owner_id != user.id ->
        Phoenix.PubSub.unsubscribe(Core.PubSub, "upload:#{image_id}")
        conn |> put_status(403) |> json(%{error: "forbidden"})

      %{
        status: status,
        book_id: book_id_bin,
        book_ids: book_ids_bins,
        rejection_reason: rejection_reason
      } ->
        book_id_str = decode_uuid(book_id_bin)
        book_ids_strs = decode_uuid_list(book_ids_bins)
        effective_ids = effective_book_ids(book_ids_strs, book_id_str)
        is_duplicate = Enum.any?(effective_ids, &Shelving.book_on_any_shelf?(user.id, &1))

        payload =
          ProtoJSON.poll_response(%{
            image_id: image_id,
            status: status,
            book_id: book_id_str,
            book_ids: effective_ids,
            rejection_reason: rejection_reason,
            is_duplicate: is_duplicate
          })

        if status in ["resolved", "rejected"] do
          Phoenix.PubSub.unsubscribe(Core.PubSub, "upload:#{image_id}")
          send_sse_event(conn, payload)
        else
          stream_sse(conn, image_id, payload, user)
        end
    end
  end

  defp send_sse_event(conn, payload) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "data: #{Jason.encode!(payload)}\n\n")
    conn
  end

  defp stream_sse(conn, image_id, _initial_payload, user) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    max_ms = Application.get_env(:core, :sse_max_timeout_ms, 60_000)
    deadline = System.monotonic_time(:millisecond) + max_ms
    sse_receive_loop(conn, image_id, user, deadline)
  end

  defp sse_receive_loop(conn, image_id, user, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    timeout = min(max(remaining, 0), 15_000)

    receive do
      {:upload_complete, %{status: status} = msg} ->
        Phoenix.PubSub.unsubscribe(Core.PubSub, "upload:#{image_id}")
        book_ids = Map.get(msg, :book_ids, [])
        book_id = List.first(book_ids)
        rejection_reason = Map.get(msg, :rejection_reason)
        is_duplicate = Enum.any?(book_ids, &Shelving.book_on_any_shelf?(user.id, &1))

        payload =
          ProtoJSON.poll_response(%{
            image_id: image_id,
            status: status,
            book_id: book_id,
            book_ids: book_ids,
            rejection_reason: rejection_reason,
            is_duplicate: is_duplicate
          })

        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(payload)}\n\n")
        conn

      :heartbeat ->
        {:ok, conn} = chunk(conn, "data: {\"type\":\"heartbeat\"}\n\n")
        sse_receive_loop(conn, image_id, user, deadline)
    after
      timeout ->
        if remaining <= 0 do
          Phoenix.PubSub.unsubscribe(Core.PubSub, "upload:#{image_id}")

          :telemetry.execute(
            [:stacks, :upload, :terminal],
            %{count: 1},
            %{outcome: :timeout}
          )

          timeout_payload =
            ProtoJSON.poll_response(%{
              image_id: image_id,
              status: "timeout",
              book_id: nil,
              book_ids: [],
              rejection_reason: nil,
              is_duplicate: false
            })

          {:ok, conn} = chunk(conn, "data: " <> Jason.encode!(timeout_payload) <> "\n\n")
          conn
        else
          {:ok, conn} = chunk(conn, "data: {\"type\":\"heartbeat\"}\n\n")
          sse_receive_loop(conn, image_id, user, deadline)
        end
    end
  end

  defp effective_book_ids([_ | _] = ids, _), do: ids
  defp effective_book_ids([], nil), do: []
  defp effective_book_ids([], book_id), do: [book_id]

  defp decode_uuid(nil), do: nil
  defp decode_uuid(<<_::128>> = bin), do: elem(Ecto.UUID.load(bin), 1)
  defp decode_uuid(str) when is_binary(str) and byte_size(str) == 36, do: str
  defp decode_uuid(_), do: nil

  defp decode_uuid_list(nil), do: []
  defp decode_uuid_list(bins), do: Enum.map(bins, &decode_uuid/1) |> Enum.reject(&is_nil/1)
end
