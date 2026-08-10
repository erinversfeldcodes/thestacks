defmodule Stacks.Workers.LibraryImportRowRetentionJob do
  @moduledoc """
  Nightly sweep of raw library-import rows past their 30-day retention
  (US-1.1.9 §11). A raw row carries the reader's own free text — Goodreads
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
end
