defmodule Stacks.Workers.LibraryImportRowRetentionJob do
  @moduledoc """
      Nightly sweep of raw library-import rows past their 30-day retention. A raw row carries the reader's own free text — Goodreads
      reviews and private notes — which exists to power the one-time per-row
      report, not to accumulate. The import record and its counts survive as the
      durable summary; the raw material does not.

      Same GDPR posture as `ImageRetentionJob`: data collected for a purpose is
      deleted when the purpose is served, on a schedule, without being asked.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Imports

  @impl true
  def perform(_job) do
    deleted = Imports.delete_expired_rows()

    if deleted > 0 do
      Logger.info("LibraryImportRowRetentionJob: deleted #{deleted} expired import rows")
    end

    :ok
  end

  @doc """
      How many raw import rows remain past the retention window. Zero after a
      complete run.

      ⚠️ Reader free text, so a non-zero number here is a data-minimisation
      finding rather than untidiness. Delegates to
      `Imports.expired_row_count/0`, which shares its cutoff with
      `Imports.delete_expired_rows/0`.
  """
  @spec pending_count() :: non_neg_integer()
  def pending_count, do: Imports.expired_row_count()
end
