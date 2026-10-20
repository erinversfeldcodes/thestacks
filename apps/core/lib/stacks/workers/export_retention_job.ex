defmodule Stacks.Workers.ExportRetentionJob do
  @moduledoc """
      Hourly sweep that removes GDPR export objects past the deadline written
      into their storage key.

      The signed link dies at that same instant, so this job is not what stops
      a stale export being downloaded — it is what stops a copy of somebody's
      personal data sitting in a bucket forever. It runs hourly rather than
      nightly so the object outlives its own link by an hour at worst.
  """

  use Stacks.Worker, scope: :system, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.GDPR.ExportDelivery

  @impl true
  def perform(_job) do
    case ExportDelivery.sweep_expired() do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("ExportRetentionJob: deleted #{count} expired export object(s)")
        :ok

      {:error, reason} ->
        Logger.error("ExportRetentionJob: sweep failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
      How many export artefacts remain past their deadline. Zero after a
      complete run.

      Delegates to `ExportDelivery.expired_count/1`, which reuses the same
      `past_deadline?/2` predicate `sweep_expired/1` splits on.
  """
  @spec pending_count() :: non_neg_integer()
  def pending_count, do: ExportDelivery.expired_count()
end
