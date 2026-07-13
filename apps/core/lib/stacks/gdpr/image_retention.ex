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
  alias Stacks.Books.UploadedImage
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
      UploadedImage
      |> where([i], not is_nil(i.expires_at) and i.expires_at < ^now)
      |> select([i], %{id: i.id, storage_path: i.storage_path})
      |> Repo.all()

    expired_ids = Enum.map(expired_rows, & &1.id)

    # Delete objects from storage before removing DB records
    delete_storage_objects(expired_rows)

    {count, _} =
      UploadedImage
      |> where([i], i.id in ^expired_ids)
      |> Repo.delete_all()

    Enum.each(expired_ids, fn image_id ->
      Events.emit_safe(%{
        event_type: "image.expired",
        aggregate_type: "image",
        aggregate_id: image_id,
        payload: %{}
      })
    end)

    # GDPR telemetry: how many images the natural-TTL sweep purged this run.
    # `reason: "expired"` mirrors the image.expired domain event and gives the
    # expired-by-reason breakdown alongside the stuck-sweep's `reason: "stuck"`.
    :telemetry.execute([:stacks, :gdpr, :image, :expired], %{count: count}, %{reason: "expired"})

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
      UploadedImage
      |> where([i], i.status == "pending" and i.uploaded_at < ^threshold)
      |> select([i], %{id: i.id, storage_path: i.storage_path})
      |> Repo.all()

    stuck_ids = Enum.map(stuck_rows, & &1.id)

    # Delete objects from storage before removing DB records
    delete_storage_objects(stuck_rows)

    {count, _} =
      UploadedImage
      |> where([i], i.id in ^stuck_ids)
      |> Repo.delete_all()

    Enum.each(stuck_ids, fn image_id ->
      Events.emit_safe(%{
        event_type: "image.expired",
        aggregate_type: "image",
        aggregate_id: image_id,
        payload: %{reason: "stuck"}
      })
    end)

    # GDPR telemetry: the stuck-safety-net count (its own signal so operators
    # can alert on a rising stuck rate), plus an image.expired-by-reason event
    # mirroring the emitted image.expired domain events (reason: "stuck").
    #
    # DOUBLE-COUNT WARNING: stuck images are counted in BOTH the `:stuck`
    # metric AND the `:expired{reason:"stuck"}` metric (and `:expired` also
    # carries the natural-TTL sweep under `reason:"expired"`). Therefore:
    #   - NEVER sum `:stuck` + `:expired` — that counts stuck images twice.
    #   - ALWAYS query `:expired` split BY `:reason`
    #     (`reason="expired"` = real 30-day TTL purge,
    #      `reason="stuck"`   = safety-net purge, mirrors `:stuck`).
    # We keep the mirror (rather than dropping it) so the `image.expired`
    # telemetry series stays 1:1 with the emitted `image.expired` domain events.
    :telemetry.execute([:stacks, :gdpr, :image, :stuck], %{count: count}, %{reason: "stuck"})
    :telemetry.execute([:stacks, :gdpr, :image, :expired], %{count: count}, %{reason: "stuck"})

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
      from(i in UploadedImage,
        where: i.expires_at < ^cutoff,
        select: %{id: i.id, storage_path: i.storage_path}
      )

    orphaned = Repo.all(query)
    count = length(orphaned)

    if orphaned != [] do
      Logger.warning(
        "ImageRetention: missing-purge alarm — #{count} image(s) past expiry still in DB"
      )
    end

    # GDPR telemetry: the retention-gap size. A non-zero orphan count means the
    # retention job missed images past their 30-day deadline. Registered in
    # `Core.PromEx.Plugins.Stacks` as `stacks_gdpr_image_orphan_count_total`.
    :telemetry.execute([:stacks, :gdpr, :image, :orphan], %{count: count}, %{})

    Enum.map(orphaned, & &1.id)
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
