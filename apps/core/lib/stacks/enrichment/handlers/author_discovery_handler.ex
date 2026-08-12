defmodule Stacks.Enrichment.Handlers.AuthorDiscoveryHandler do
  @moduledoc """
      Handler for `book.created` — INTENTIONALLY a no-op in the steady state.
      The per-book `DiscoverAuthorSourcesJob` enqueue was removed: every new
      book fired a Brave Search call against a 2000/month free tier, and
      exhaustion pushed the Oban failure rate past the SLO gate. Author-source
      discovery is not on the upload critical path; the job's `batch: true`
      mode drains `authors_without_sources` from cron instead. The module
      stays registered so the subscription (and this rationale) survives.
  """

  @behaviour Stacks.Events.Handler

  @impl true
  def handle_event(_event), do: :ok
end
