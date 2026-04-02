defmodule Stacks.Workers.IdentifyBookJob do
  @moduledoc """
  Oban worker that processes an uploaded image through the Modal vision service
  to identify and create/update a book record.

  New jobs receive a `storage_key` in args and fetch a presigned URL at execution
  time. Legacy in-flight jobs that still carry `image_b64` are handled via
  backwards-compatible pattern matching.
  """

  use Oban.Worker, queue: :vision, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Books.UploadedImage
  alias Stacks.Events
  alias Stacks.Moderation
  alias Stacks.Storage

  # ── New path: storage_key ─────────────────────────────────────────────────

  @impl true
  def perform(%Oban.Job{
        args: %{"user_id" => user_id, "image_id" => image_id, "storage_key" => storage_key}
      }) do
    Logger.info("IdentifyBookJob: processing image #{image_id} for user #{user_id}")

    case Storage.get_image_url(storage_key) do
      {:ok, image_url} ->
        context = %{
          image_url: image_url,
          user_id: user_id,
          image_id: image_id
        }

        run_pipeline(context, image_id)

      {:error, reason} ->
        Logger.error(
          "IdentifyBookJob: failed to get presigned URL for #{storage_key}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # ── Legacy path: image_b64 (backwards compat for in-flight jobs) ──────────

  def perform(%Oban.Job{
        args: %{"user_id" => user_id, "image_id" => image_id, "image_b64" => image_b64}
      }) do
    Logger.info(
      "IdentifyBookJob: processing image #{image_id} for user #{user_id} (legacy b64 path)"
    )

    context = %{
      image_b64: image_b64,
      user_id: user_id,
      image_id: image_id
    }

    run_pipeline(context, image_id)
  end

  defp run_pipeline(context, image_id) do
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
    query = from(i in UploadedImage, where: i.id == ^image_id)

    {count, _} =
      Repo.update_all(
        query,
        set: [
          status: "resolved",
          book_id: List.first(book_ids),
          book_ids: book_ids,
          updated_at: DateTime.utc_now()
        ]
      )

    if count > 0 do
      Logger.info("IdentifyBookJob: resolved image #{image_id} → #{length(book_ids)} book(s)")

      Phoenix.PubSub.broadcast(
        Core.PubSub,
        "upload:#{image_id}",
        {:upload_complete, %{status: "resolved", book_ids: book_ids}}
      )

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
    query = from(i in UploadedImage, where: i.id == ^image_id)

    {count, _} =
      Repo.update_all(
        query,
        set: [
          status: "rejected",
          rejection_reason: reason,
          updated_at: DateTime.utc_now()
        ]
      )

    if count > 0 do
      Logger.info("IdentifyBookJob: rejected image #{image_id} (#{reason})")

      Phoenix.PubSub.broadcast(
        Core.PubSub,
        "upload:#{image_id}",
        {:upload_complete, %{status: "rejected", rejection_reason: reason}}
      )

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
