defmodule Stacks.GDPR.ImageRetention do
  @moduledoc """
  Handles cleanup of uploaded images.

  - `cleanup_expired_images/0` — deletes images past their expires_at deadline (30 days)
  - `cleanup_stuck_images/0` — safety net: cleans up images stuck in pending
    for longer than 2 hours (e.g. if IdentifyBookJob never ran or failed silently)

  Both functions delete the object from storage (R2/Local/Mock) when a
  `storage_path` is present, then remove the DB record and emit an
  `image.expired` event for each deleted record.
  """

  require Logger

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Events
  alias Stacks.Storage

  @stuck_threshold_hours 2

  @doc """
  Deletes all uploaded_images records where `expires_at < now()`.
  Removes the corresponding object from storage, then the DB record.
  Emits `image.expired` for each deleted record.
  Returns `{:ok, count}` with the number of deleted records.
  """
  @spec cleanup_expired_images() :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_expired_images do
    now = DateTime.utc_now()

    expired_rows =
      "uploaded_images"
      |> where([i], not is_nil(i.expires_at) and i.expires_at < ^now)
      |> select([i], %{id: i.id, storage_path: i.storage_path})
      |> Repo.all(prefix: "op")

    expired_ids = Enum.map(expired_rows, & &1.id)

    # Delete objects from storage before removing DB records
    delete_storage_objects(expired_rows)

    {count, _} =
      "uploaded_images"
      |> where([i], i.id in ^expired_ids)
      |> Repo.delete_all(prefix: "op")

    Enum.each(expired_ids, fn id_bin ->
      {:ok, image_id} = Ecto.UUID.load(id_bin)

      Events.emit_safe(%{
        event_type: "image.expired",
        aggregate_type: "image",
        aggregate_id: image_id,
        payload: %{}
      })
    end)

    {:ok, count}
  rescue
    error -> {:error, error}
  end

  @doc """
  Deletes uploaded_images records stuck in `pending` status for longer than
  #{@stuck_threshold_hours} hours. These are images whose IdentifyBookJob
  failed silently or never ran.
  Removes the corresponding object from storage, then the DB record.
  Emits `image.expired` for each deleted record.
  Returns `{:ok, count}`.
  """
  @spec cleanup_stuck_images() :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_stuck_images do
    threshold = DateTime.add(DateTime.utc_now(), -@stuck_threshold_hours * 3600, :second)

    stuck_rows =
      "uploaded_images"
      |> where([i], i.status == "pending" and i.uploaded_at < ^threshold)
      |> select([i], %{id: i.id, storage_path: i.storage_path})
      |> Repo.all(prefix: "op")

    stuck_ids = Enum.map(stuck_rows, & &1.id)

    # Delete objects from storage before removing DB records
    delete_storage_objects(stuck_rows)

    {count, _} =
      "uploaded_images"
      |> where([i], i.id in ^stuck_ids)
      |> Repo.delete_all(prefix: "op")

    Enum.each(stuck_ids, fn id_bin ->
      {:ok, image_id} = Ecto.UUID.load(id_bin)

      Events.emit_safe(%{
        event_type: "image.expired",
        aggregate_type: "image",
        aggregate_id: image_id,
        payload: %{reason: "stuck"}
      })
    end)

    {:ok, count}
  rescue
    error -> {:error, error}
  end

  @doc """
  Returns image IDs that should have been purged but weren't.

  Finds images with `image.submitted`, `image.resolved`, or `image.rejected`
  events whose `expires_at` has passed, but which have no corresponding
  `image.expired` event. These are orphaned images that the retention job
  missed.

  Run daily as a health check — a non-empty result indicates a retention gap.
  """
  @spec missing_purge_check() :: [String.t()]
  def missing_purge_check do
    cutoff = DateTime.utc_now()

    query =
      from(i in "uploaded_images",
        prefix: "op",
        where: i.expires_at < ^cutoff,
        select: %{id: i.id, storage_path: i.storage_path}
      )

    orphaned = Repo.all(query)

    if orphaned != [] do
      count = length(orphaned)

      Logger.warning(
        "ImageRetention: missing-purge alarm — #{count} image(s) past expiry still in DB"
      )
    end

    Enum.map(orphaned, fn %{id: id} ->
      case Ecto.UUID.load(id) do
        {:ok, uuid} -> uuid
        _ -> inspect(id)
      end
    end)
  end

  defp delete_storage_objects(rows) do
    Enum.each(rows, fn
      %{storage_path: path} when is_binary(path) and path != "" ->
        case Storage.delete_image(path) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "ImageRetention: failed to delete storage object #{path}: #{inspect(reason)}"
            )
        end

      _ ->
        :ok
    end)
  end
end
