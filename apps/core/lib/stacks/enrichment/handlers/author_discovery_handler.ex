defmodule Stacks.Enrichment.Handlers.AuthorDiscoveryHandler do
  @moduledoc """
  Event handler for `book.created` events. **Intentionally a no-op in
  the steady state** — the per-book enqueue of `DiscoverAuthorSourcesJob`
  was removed because:

    1. Every new book fired one Brave Search call, and Brave's free tier
       is capped at 2000/month (≈67/day). A modestly active user would
       blow the budget in an afternoon, at which point every subsequent
       job returned `{:error, :daily_budget_exhausted}` — pushing
       `oban_failure_rate_default` to >90% and poisoning the SLO gate.

    2. Author-source discovery is **nice-to-have**, not on the upload
       critical path. It powers RSS/blog ingestion, which happens
       asynchronously and only needs to be current-ish.

  The work hasn't gone away — `DiscoverAuthorSourcesJob` still has a
  `%{"batch" => true}` mode that processes `authors_without_sources()`
  in one pass. It runs from cron (see `crontab` in `config/config.exs`)
  and drains the queue at whatever rate the Brave daily budget allows.

  Kept as a no-op handler rather than deleted so the event-registry
  wiring doesn't go stale; future signals might still want per-book
  hooks (e.g. updating a cached `last_seen_at` for author prioritisation
  in the batch).
  """

  @behaviour Stacks.Events.Handler

  @impl true
  def handle_event(_event), do: :ok
end
