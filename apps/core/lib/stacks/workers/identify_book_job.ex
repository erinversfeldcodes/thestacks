defmodule Stacks.Workers.IdentifyBookJob do
  @moduledoc """
  Oban worker that processes an uploaded image through the Modal vision service
  to identify and create/update a book record.

  The image is passed as base64 in the job args — no filesystem access needed.
  This means any Fly machine can execute the job regardless of which machine
  handled the original upload.
  """

  use Oban.Worker, queue: :vision, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Events
  alias Stacks.Moderation

  @impl true
  def perform(%Oban.Job{
        args: %{"user_id" => user_id, "image_id" => image_id, "image_b64" => image_b64}
      }) do
    Logger.info("IdentifyBookJob: processing image #{image_id} for user #{user_id}")

    context = %{
      image_b64: image_b64,
      user_id: user_id,
      image_id: image_id
    }

    case Moderation.run_pipeline(context) do
      {:ok, books} when is_list(books) ->
        book_ids = Enum.map(books, & &1.id)
        isbns = Enum.map_join(books, ", ", &primary_isbn/1)

        Logger.info("IdentifyBookJob: identified #{length(books)} book(s): #{isbns}")
        mark_resolved(image_id, book_ids)
        :ok

      {:error, :not_a_book} ->
        Logger.warning("IdentifyBookJob: image #{image_id} is not a book")
        mark_rejected(image_id, "not_a_book")
        {:cancel, "image does not contain a book"}

      {:error, :isbn_not_found} ->
        Logger.warning("IdentifyBookJob: could not extract ISBN from image #{image_id}")
        mark_rejected(image_id, "isbn_not_found")
        {:cancel, "isbn_not_found"}

      {:error, reason} ->
        Logger.error("IdentifyBookJob: pipeline failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    exception ->
      Logger.error(
        "IdentifyBookJob: unhandled exception for image #{image_id}: #{Exception.format(:error, exception, __STACKTRACE__)}"
      )

      {:error, exception}
  end

  defp primary_isbn(%{editions: [edition | _]}), do: edition.isbn
  defp primary_isbn(_book), do: "unknown"

  defp mark_resolved(image_id, book_ids) when is_list(book_ids) do
    {:ok, image_id_bin} = Ecto.UUID.dump(image_id)
    book_id_bins = Enum.map(book_ids, fn id -> elem(Ecto.UUID.dump(id), 1) end)
    first_book_id_bin = List.first(book_id_bins)

    query = from(i in "uploaded_images", where: i.id == ^image_id_bin)

    {count, _} =
      Repo.update_all(
        query,
        [
          set: [
            status: "resolved",
            book_id: first_book_id_bin,
            book_ids: book_id_bins,
            updated_at: DateTime.utc_now()
          ]
        ],
        prefix: "op"
      )

    if count > 0 do
      Logger.info("IdentifyBookJob: resolved image #{image_id} → #{length(book_ids)} book(s)")

      Events.emit_safe(%{
        event_type: "image.resolved",
        aggregate_type: "image",
        aggregate_id: image_id,
        payload: %{book_count: length(book_ids)}
      })
    else
      Logger.warning("IdentifyBookJob: image #{image_id} not found for resolve")
    end
  rescue
    error ->
      Logger.error("IdentifyBookJob: failed to resolve image #{image_id}: #{inspect(error)}")
  end

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

      Events.emit_safe(%{
        event_type: "image.rejected",
        aggregate_type: "image",
        aggregate_id: image_id,
        payload: %{reason: reason}
      })
    else
      Logger.warning("IdentifyBookJob: image #{image_id} not found for reject")
    end
  rescue
    error ->
      Logger.error("IdentifyBookJob: failed to reject image #{image_id}: #{inspect(error)}")
  end
end
