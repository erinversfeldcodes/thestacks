defmodule Stacks.GDPR.ImageRetention do
  @moduledoc """
  Handles cleanup of uploaded images.

  - `cleanup_expired_images/0` — deletes images past their expires_at deadline
  - `cleanup_stuck_images/0` — safety net: cleans up images stuck in pending/processing
    for longer than 2 hours (the IdentifyBookJob normally handles deletion on success)
  """

  import Ecto.Query

  alias Core.Repo

  @stuck_threshold_hours 2

  @doc """
  Deletes all uploaded_images records where `expires_at < now()`.
  Returns `{:ok, count}` with the number of deleted records.
  """
  @spec cleanup_expired_images() :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_expired_images do
    now = DateTime.utc_now()

    expired_query =
      "uploaded_images"
      |> where([i], not is_nil(i.expires_at) and i.expires_at < ^now)

    {count, _} = Repo.delete_all(expired_query, prefix: "op")
    {:ok, count}
  rescue
    error -> {:error, error}
  end

  @doc """
  Deletes uploaded_images records stuck in `pending` status for longer than
  #{@stuck_threshold_hours} hours. These are images whose IdentifyBookJob
  failed silently or never ran.
  Returns `{:ok, count}`.
  """
  @spec cleanup_stuck_images() :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_stuck_images do
    threshold = DateTime.add(DateTime.utc_now(), -@stuck_threshold_hours * 3600, :second)

    stuck_query =
      "uploaded_images"
      |> where([i], i.status == "pending" and i.uploaded_at < ^threshold)

    {count, _} = Repo.delete_all(stuck_query, prefix: "op")
    {:ok, count}
  rescue
    error -> {:error, error}
  end
end
