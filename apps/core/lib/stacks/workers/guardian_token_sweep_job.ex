defmodule Stacks.Workers.GuardianTokenSweepJob do
  @moduledoc """
  Daily Oban cron worker that reaps dead server-side auth state (Issue #124,
  A2 — P1 companion to server-side JWT revocation; extended for Issue #179).

  Two tables grow unbounded without a periodic sweep:

    * `op.guardian_tokens` — `Guardian.revoke/1` deletes a row on logout, but an
      access token that simply *expires* (its 8h ttl elapses without an explicit
      logout) leaves a dead row behind. Delegated to
      `Guardian.DB.Token.purge_expired_tokens/0`, a single indexed
      `DELETE ... WHERE exp < now()`.

    * `op.auth_token_families` — refresh-token families (Issue #179). A family is
      *dead* once it is long-revoked, or so far past the absolute session cap
      that no live token can still exist for it. Live families (unrevoked and
      within the cap) are NEVER deleted.

  Scheduled daily at 00:00 UTC via the Oban crontab in `config/config.exs`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Core.Repo
  alias Guardian.DB.Token
  alias Stacks.Accounts.AuthTokenFamily

  # Grace period kept AFTER a family becomes dead before it is physically
  # removed. Conservative: a revoked family is already rejected by the
  # verify_claims gate, so retention only affects table size, not security.
  @family_retention_seconds 7 * 86_400

  @impl true
  def perform(_job) do
    {deleted_tokens, _} = Token.purge_expired_tokens()
    deleted_families = prune_dead_families()

    Logger.info(
      "GuardianTokenSweepJob: purged #{deleted_tokens} expired guardian_tokens rows, " <>
        "#{deleted_families} dead auth_token_families rows"
    )

    :ok
  end

  # Delete families that are provably dead:
  #   * revoked more than @family_retention_seconds ago, OR
  #   * started so long ago that they are past the absolute session cap plus the
  #     retention grace (past the cap the session can no longer be refreshed and
  #     the last access token's 8h ttl is long gone, so no live token remains).
  # A live family (revoked_at IS NULL and session within the cap) matches
  # neither predicate and is preserved.
  defp prune_dead_families do
    now = DateTime.utc_now()
    revoked_cutoff = DateTime.add(now, -@family_retention_seconds, :second)
    cap_cutoff = DateTime.add(now, -(session_cap_seconds() + @family_retention_seconds), :second)

    {count, _} =
      from(f in AuthTokenFamily,
        where:
          (not is_nil(f.revoked_at) and f.revoked_at < ^revoked_cutoff) or
            f.session_started_at < ^cap_cutoff
      )
      |> Repo.delete_all()

    count
  end

  # Absolute session cap in seconds, mirroring AuthController's `{n, unit}`
  # config shape so the two never disagree on how long a session may live.
  defp session_cap_seconds do
    {n, unit} = Application.get_env(:core, :session_absolute_cap, {7, :day})
    n * unit_in_seconds(unit)
  end

  defp unit_in_seconds(:second), do: 1
  defp unit_in_seconds(:minute), do: 60
  defp unit_in_seconds(:hour), do: 3_600
  defp unit_in_seconds(:day), do: 86_400
  defp unit_in_seconds(:week), do: 604_800
end
