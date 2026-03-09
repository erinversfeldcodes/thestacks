defmodule StacksWeb.UploadController do
  @moduledoc "Handles image uploads and enqueues identification jobs."

  use CoreWeb, :controller

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Accounts.Guardian
  alias Stacks.Books
  alias Stacks.Shelving

  @doc "POST /api/upload — accepts a multipart image upload and enqueues IdentifyBookJob."
  def create(conn, %{"image" => %Plug.Upload{} = upload}) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, image} <- Books.store_upload(user.id, upload),
         {:ok, _job} <- Books.upload_and_identify(user.id, image.id) do
      conn
      |> put_status(202)
      |> json(%{status: "accepted", image_id: image.id})
    else
      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: inspect(reason)})
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
        select: %{status: i.status, book_id: i.book_id, rejection_reason: i.rejection_reason}
      )
      |> Repo.one(prefix: "op")

    case result do
      nil ->
        conn |> put_status(404) |> json(%{error: "not found"})

      %{status: status, book_id: book_id_bin, rejection_reason: rejection_reason} ->
        book_id_str = decode_book_id(book_id_bin)
        user = Guardian.Plug.current_resource(conn)
        is_duplicate = book_id_str != nil and Shelving.book_on_any_shelf?(user.id, book_id_str)

        json(conn, %{
          image_id: image_id,
          status: status,
          book_id: book_id_str,
          rejection_reason: rejection_reason,
          is_duplicate: is_duplicate
        })
    end
  end

  defp decode_book_id(nil), do: nil
  defp decode_book_id(bin), do: elem(Ecto.UUID.load(bin), 1)
end
