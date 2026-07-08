defmodule Stacks.Workers.GuardianTokenSweepJob do
  @moduledoc """
  Daily Oban cron worker that reaps expired rows from `op.guardian_tokens`
  (Issue #124, A2 — P1 companion to server-side JWT revocation).

  `Guardian.revoke/1` deletes a token row on logout, but an access token that
  simply *expires* — its 8h ttl elapses without an explicit logout — leaves a
  dead row behind. Without a periodic sweep the table grows unbounded: every
  session ever issued becomes a permanent tombstone, inflating backup size and
  degrading the presence-check query plan on every verify.

  Delegates to `Guardian.DB.Token.purge_expired_tokens/0`, which issues a single
  `DELETE ... WHERE exp < now()` against the (indexed) `exp` column, so the sweep
  stays cheap as the table grows.

  Scheduled daily at 00:00 UTC via the Oban crontab in `config/config.exs`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Guardian.DB.Token

  @impl true
  def perform(_job) do
    {deleted, _} = Token.purge_expired_tokens()

    Logger.info("GuardianTokenSweepJob: purged #{deleted} expired guardian_tokens rows")

    :ok
  end
end
