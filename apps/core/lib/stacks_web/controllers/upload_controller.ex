defmodule StacksWeb.UploadController do
  @moduledoc "Handles image uploads and enqueues identification jobs."

  use CoreWeb, :controller

  alias Stacks.Accounts.Guardian
  alias Stacks.Books

  @doc "POST /api/upload — accepts a multipart image upload and enqueues IdentifyBookJob."
  def create(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    case extract_image(params) do
      {:ok, image_id} ->
        case Books.upload_and_identify(user.id, image_id) do
          {:ok, _job} ->
            conn
            |> put_status(202)
            |> json(%{status: "accepted", image_id: image_id})

          {:error, reason} ->
            conn
            |> put_status(500)
            |> json(%{error: inspect(reason)})
        end

      {:error, :no_image} ->
        conn
        |> put_status(422)
        |> json(%{error: "no image provided"})
    end
  end

  defp extract_image(%{"image" => %Plug.Upload{} = upload}) do
    # In production: stream to object storage, return storage key
    # For now, use a generated ID based on the filename
    image_id = Ecto.UUID.generate()
    _ = upload
    {:ok, image_id}
  end

  defp extract_image(%{"image_id" => image_id}) when is_binary(image_id) do
    {:ok, image_id}
  end

  defp extract_image(_), do: {:error, :no_image}
end
