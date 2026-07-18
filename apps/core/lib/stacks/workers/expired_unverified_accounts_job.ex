defmodule Stacks.Workers.ExpiredUnverifiedAccountsJob do
  @moduledoc """
  Daily Oban worker that reaps abandoned signups: accounts that never confirmed
  their email and whose confirmation link has expired
  (`Accounts.unverified_account_ttl_seconds/0` after creation — 24h). Scheduled
  via the crontab in `config/config.exs`.

  Each expired account is erased through the full GDPR right-to-erasure path
  (`Stacks.GDPR.Deletion.delete_user_data/2`), so the personal data (email,
  password hash, handle) is removed, an audit row is written, and the
  UUID-only `user.registered` event is scrubbed — identical to any other
  erasure. Unverified accounts have never logged in, so they carry no
  bookshelves/placements/comments/sessions; the erasure is cheap.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Accounts
  alias Stacks.GDPR.Deletion

  @impl true
  def perform(_job) do
    ids = Accounts.expired_unverified_ids()

    {erased, failed} =
      Enum.reduce(ids, {0, 0}, fn id, {ok, err} ->
        case Deletion.delete_user_data(id,
               reason: "unverified account expired — email never confirmed within TTL",
               actor: "expired-unverified-reaper"
             ) do
          {:ok, _} ->
            {ok + 1, err}

          {:error, step, reason, _changes} ->
            Logger.error(
              "ExpiredUnverifiedAccountsJob: erase failed for #{id} at #{step}: #{inspect(reason)}"
            )

            {ok, err + 1}
        end
      end)

    Logger.info(
      "ExpiredUnverifiedAccountsJob: erased #{erased} expired unverified account(s), #{failed} failed"
    )

    :telemetry.execute(
      [:stacks, :accounts, :unverified_reaped],
      %{erased: erased, failed: failed},
      %{}
    )

    if failed > 0, do: {:error, :partial_failure}, else: :ok
  end
end
