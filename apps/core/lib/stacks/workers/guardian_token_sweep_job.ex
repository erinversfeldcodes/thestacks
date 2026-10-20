defmodule Stacks.Workers.GuardianTokenSweepJob do
  @moduledoc """
      Daily cron (00:00 UTC) reaping dead server-side auth state:
      `op.guardian_tokens` rows whose ttl expired without an explicit logout
      (delegated to `Guardian.DB.Token.purge_expired_tokens/0`), and
      `op.auth_token_families` that are long-revoked or past the absolute
      session cap. Live families — unrevoked, within the cap — are NEVER
      deleted.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Core.Repo
  alias Guardian.DB.Token
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.Duration

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

  defp prune_dead_families do
    {count, _} = Repo.delete_all(dead_families())
    count
  end

  @doc """
      How many rows remain that this job sweeps: expired `guardian_tokens` plus
      dead `auth_token_families`. Zero after a complete run.

      ⚠️ The two halves are counted differently and deliberately. The families
      half shares `dead_families/0` with the sweep, so it cannot drift. The
      token half is deleted by `Guardian.DB.Token.purge_expired_tokens/0`, a
      dependency, so there is no shared predicate to borrow — it is counted
      here against `exp`, the unix-epoch column that function compares, which
      is a restatement and the one place this count could drift from its sweep.
      Said out loud rather than left for someone to discover.
  """
  @spec pending_count() :: non_neg_integer()
  def pending_count do
    now_unix = DateTime.to_unix(DateTime.utc_now())

    %{rows: [[expired_tokens]]} =
      Repo.query!("SELECT count(*) FROM op.guardian_tokens WHERE exp < $1", [now_unix])

    expired_tokens + Repo.aggregate(dead_families(), :count)
  end

  defp dead_families do
    now = DateTime.utc_now()
    revoked_cutoff = DateTime.add(now, -@family_retention_seconds, :second)
    cap_cutoff = DateTime.add(now, -(session_cap_seconds() + @family_retention_seconds), :second)

    from(f in AuthTokenFamily,
      where:
        (not is_nil(f.revoked_at) and f.revoked_at < ^revoked_cutoff) or
          f.session_started_at < ^cap_cutoff
    )
  end

  defp session_cap_seconds do
    :core
    |> Application.get_env(:session_absolute_cap, {7, :day})
    |> Duration.to_seconds()
  end
end
