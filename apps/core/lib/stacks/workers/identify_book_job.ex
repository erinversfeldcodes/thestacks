defmodule Stacks.Workers.IdentifyBookJob do
  @moduledoc """
  Oban worker that processes an uploaded image through the vision sidecar
  to identify and create/update a book record.

  On success, immediately marks the uploaded image as resolved and deletes it.
  The nightly ImageRetentionJob handles any stuck pending/processing images.
  """

  use Oban.Worker, queue: :vision, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Moderation

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id, "image_id" => image_id}}) do
    Logger.info("IdentifyBookJob: processing image #{image_id} for user #{user_id}")

    with {:ok, image_b64} <- load_image_b64(image_id) do
      context = %{
        image_b64: image_b64,
        user_id: user_id,
        image_id: image_id
      }

      case Moderation.run_pipeline(context) do
        {:ok, book} ->
          Logger.info("IdentifyBookJob: identified book #{book.id} (ISBN: #{book.isbn})")
          mark_resolved(image_id, book.id)
          :ok

        {:error, :not_a_book} ->
          Logger.warning("IdentifyBookJob: image #{image_id} is not a book")
          mark_rejected(image_id, "not_a_book")
          {:cancel, "image does not contain a book"}

        {:error, :isbn_not_found} ->
          Logger.warning("IdentifyBookJob: could not extract ISBN from image #{image_id}")
          # Cancel rather than retry — the image content won't change on retry.
          mark_rejected(image_id, "isbn_not_found")
          {:cancel, "isbn_not_found"}

        {:error, reason} ->
          Logger.error("IdentifyBookJob: pipeline failed: #{inspect(reason)}")
          # Unknown errors may be transient (network, sidecar down) — allow Oban retries.
          {:error, reason}
      end
    end
  end

  # Reads the uploaded image from disk and returns it base64-encoded.
  defp load_image_b64(image_id) do
    upload_dir = Application.get_env(:core, :upload_dir, "priv/static/uploads")

    # Look up storage_path (includes extension) from DB.
    {:ok, image_id_bin} = Ecto.UUID.dump(image_id)

    storage_path =
      from(i in "uploaded_images", where: i.id == ^image_id_bin, select: i.storage_path)
      |> Repo.one(prefix: "op")

    case storage_path do
      nil -> {:error, :image_not_found}
      path -> read_upload_file(upload_dir, path)
    end
  end

  # Sanitise and read an upload file. `Path.basename` strips any leading "../" or
  # subdirectory segments; the guard rejects anything that still looks traversal-like.
  # sobelow_skip ["Traversal.FileModule"] -- path is basename-only, no separators;
  # store_upload/2 controls all writes into upload_dir.
  defp read_upload_file(upload_dir, path) do
    safe_name = Path.basename(path)

    if valid_upload_filename?(safe_name) do
      case File.read(Path.join(upload_dir, safe_name)) do
        {:ok, bytes} -> {:ok, Base.encode64(bytes)}
        {:error, reason} -> {:error, {:file_read, reason}}
      end
    else
      {:error, :invalid_storage_path}
    end
  end

  defp valid_upload_filename?(name) do
    name != "" and name != "." and name != ".." and
      not String.contains?(name, "/") and not String.contains?(name, "\\")
  end

  # Marks an image as resolved and records which book was identified.
  defp mark_resolved(image_id, book_id) do
    {:ok, image_id_bin} = Ecto.UUID.dump(image_id)
    {:ok, book_id_bin} = Ecto.UUID.dump(book_id)

    query = from(i in "uploaded_images", where: i.id == ^image_id_bin)

    {count, _} =
      Repo.update_all(
        query,
        [set: [status: "resolved", book_id: book_id_bin, updated_at: DateTime.utc_now()]],
        prefix: "op"
      )

    if count > 0 do
      Logger.info("IdentifyBookJob: resolved image #{image_id} → book #{book_id}")
    else
      Logger.warning("IdentifyBookJob: image #{image_id} not found for resolve")
    end
  rescue
    error ->
      Logger.error("IdentifyBookJob: failed to resolve image #{image_id}: #{inspect(error)}")
  end

  # Marks an image as rejected with a reason so the poll endpoint can surface it.
  defp mark_rejected(image_id, reason) do
    {:ok, image_id_bin} = Ecto.UUID.dump(image_id)

    query = from(i in "uploaded_images", where: i.id == ^image_id_bin)

    {count, _} =
      Repo.update_all(
        query,
        [
          set: [
            status: "rejected",
            rejection_reason: reason,
            updated_at: DateTime.utc_now()
          ]
        ],
        prefix: "op"
      )

    if count > 0 do
      Logger.info("IdentifyBookJob: rejected image #{image_id} (#{reason})")
    else
      Logger.warning("IdentifyBookJob: image #{image_id} not found for reject")
    end
  rescue
    error ->
      Logger.error("IdentifyBookJob: failed to reject image #{image_id}: #{inspect(error)}")
  end
end
