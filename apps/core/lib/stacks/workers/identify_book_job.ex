defmodule Stacks.Workers.IdentifyBookJob do
  @moduledoc """
  Oban worker that processes an uploaded image through the vision sidecar
  to identify and create/update a book record.

  On success, immediately marks the uploaded image as resolved and deletes it.
  The nightly ImageRetentionJob handles any stuck pending/processing images.
  """

  use Oban.Worker, queue: :vision, max_attempts: 3

  require Logger

  alias Core.Repo
  alias Stacks.Moderation

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id, "image_id" => image_id}}) do
    Logger.info("IdentifyBookJob: processing image #{image_id} for user #{user_id}")

    image_url = build_image_url(image_id)

    context = %{
      image_url: image_url,
      user_id: user_id,
      image_id: image_id
    }

    case Moderation.run_pipeline(context) do
      {:ok, book} ->
        Logger.info("IdentifyBookJob: identified book #{book.id} (ISBN: #{book.isbn})")
        delete_uploaded_image(image_id)
        :ok

      {:error, :not_a_book} ->
        Logger.warning("IdentifyBookJob: image #{image_id} is not a book")
        delete_uploaded_image(image_id)
        {:cancel, "image does not contain a book"}

      {:error, :isbn_not_found} ->
        Logger.warning("IdentifyBookJob: could not extract ISBN from image #{image_id}")
        {:error, "isbn_not_found"}

      {:error, reason} ->
        Logger.error("IdentifyBookJob: pipeline failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp delete_uploaded_image(image_id) do
    import Ecto.Query

    query =
      from(i in "uploaded_images",
        where: i.id == ^image_id
      )

    {count, _} =
      Repo.update_all(query, [set: [status: "resolved", updated_at: DateTime.utc_now()]],
        prefix: "op"
      )

    if count > 0 do
      Logger.info("IdentifyBookJob: marked image #{image_id} as resolved")
    else
      Logger.warning("IdentifyBookJob: image #{image_id} not found for cleanup")
    end
  rescue
    error ->
      Logger.error("IdentifyBookJob: failed to clean up image #{image_id}: #{inspect(error)}")
  end

  defp build_image_url(image_id) do
    base = Application.get_env(:core, :storage_base_url, "http://localhost:4000/uploads")
    "#{base}/#{image_id}"
  end
end
