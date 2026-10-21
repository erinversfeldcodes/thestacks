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

  use Stacks.Worker, scope: :system, queue: :default, max_attempts: 3

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
               actor: "expired-unverified-reaper",
               restore_invite: true
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

  @doc """
      How many unverified registrations remain past the window.

      ⛔ NOT zero after a complete run, and the previous claim that it was is
      what made this number useless. The sweep takes at most one batch per run,
      so a backlog larger than a batch survives a complete run by design.

      ⚠️ It delegates to `Accounts.pending_unverified_count/1` rather than to
      the id-listing the sweep iterates. Sharing that listing kept the count
      honest about WHICH accounts qualify and silently shared its `limit`, so
      the figure could never exceed the batch size — ten thousand abandoned
      signups reported as the batch ceiling, every night, green. The two share
      their predicate and differ only in that this one does not stop counting.
  """
  @spec pending_count() :: non_neg_integer()
  def pending_count, do: Accounts.pending_unverified_count()
end
