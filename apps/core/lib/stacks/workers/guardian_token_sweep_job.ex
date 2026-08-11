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

  defp session_cap_seconds do
    :core
    |> Application.get_env(:session_absolute_cap, {7, :day})
    |> Duration.to_seconds()
  end
end
