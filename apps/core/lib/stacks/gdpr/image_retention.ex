defmodule Stacks.GDPR.ImageRetention do
  @moduledoc """
  Handles cleanup of uploaded images.

  - `cleanup_expired_images/0` — deletes images past their expires_at deadline (30 days)
  - `cleanup_stuck_images/0` — safety net: cleans up images stuck in pending
    for longer than 2 hours (e.g. if IdentifyBookJob never ran or failed silently)

  Both functions emit an `image.expired` event for each deleted record so the
  event log has a complete lifecycle trace for every uploaded image.
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Events

  @stuck_threshold_hours 2

  @doc """
  Deletes all uploaded_images records where `expires_at < now()`.
  Emits `image.expired` for each deleted record.
  Returns `{:ok, count}` with the number of deleted records.
  """
  @spec cleanup_expired_images() :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_expired_images do
    now = DateTime.utc_now()

    expired_ids =
      "uploaded_images"
      |> where([i], not is_nil(i.expires_at) and i.expires_at < ^now)
      |> select([i], i.id)
      |> Repo.all(prefix: "op")

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
  Emits `image.expired` for each deleted record.
  Returns `{:ok, count}`.
  """
  @spec cleanup_stuck_images() :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_stuck_images do
    threshold = DateTime.add(DateTime.utc_now(), -@stuck_threshold_hours * 3600, :second)

    stuck_ids =
      "uploaded_images"
      |> where([i], i.status == "pending" and i.uploaded_at < ^threshold)
      |> select([i], i.id)
      |> Repo.all(prefix: "op")

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
end
