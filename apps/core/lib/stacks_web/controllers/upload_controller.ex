defmodule StacksWeb.UploadController do
  @moduledoc "Handles image uploads and enqueues identification jobs."

  use CoreWeb, :controller

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Accounts.Guardian
  alias Stacks.Books
  alias Stacks.Shelving

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

    with {:ok, {image, image_b64}} <- Books.store_upload(user.id, upload),
         {:ok, _job} <- Books.upload_and_identify(user.id, image.id, image_b64) do
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

  @doc "GET /api/upload/:image_id/status — poll the status of an uploaded image."
  def status(conn, %{"image_id" => image_id}) do
    case Ecto.UUID.dump(image_id) do
      {:ok, image_id_bin} -> render_status(conn, image_id, image_id_bin)
      :error -> conn |> put_status(422) |> json(%{error: "invalid image_id"})
    end
  end

  defp render_status(conn, image_id, image_id_bin) do
    result =
      from(i in "uploaded_images",
        where: i.id == ^image_id_bin,
        select: %{
          status: i.status,
          book_id: i.book_id,
          book_ids: i.book_ids,
          rejection_reason: i.rejection_reason
        }
      )
      |> Repo.one(prefix: "op")

    case result do
      nil ->
        conn |> put_status(404) |> json(%{error: "not found"})

      %{
        status: status,
        book_id: book_id_bin,
        book_ids: book_ids_bins,
        rejection_reason: rejection_reason
      } ->
        book_id_str = decode_uuid(book_id_bin)
        book_ids_strs = decode_uuid_list(book_ids_bins)

        # Prefer book_ids array; fall back to book_id singleton for rows written
        # before the migration (book_ids defaults to []).
        effective_ids = effective_book_ids(book_ids_strs, book_id_str)

        user = Guardian.Plug.current_resource(conn)
        is_duplicate = Enum.any?(effective_ids, &Shelving.book_on_any_shelf?(user.id, &1))

        json(conn, %{
          image_id: image_id,
          status: status,
          book_id: book_id_str,
          book_ids: effective_ids,
          rejection_reason: rejection_reason,
          is_duplicate: is_duplicate
        })
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
