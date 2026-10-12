defmodule Stacks.Workers.ExpiredEmailChangesJob do
  @moduledoc """
      Daily Oban worker that withdraws confirmed status from accounts whose email
      change outlived its grace window without either address answering
      (`Accounts.email_change_grace_seconds/0` — 7 days). Scheduled via the crontab
      in `config/config.exs`.

      This sweep IS the degradation. `RequireConfirmedEmail` is not modified and
      does not know this flow exists: it keeps asking the one question it always
      asked, and the grace window is implemented by nobody answering that question
      differently until this job runs. The account keeps all of its data; only the
      flag moves, and the undo link mailed to its current address — signed for
      thirty days, deliberately longer than the window — restores it.

      Deliberately NOT folded into `ExpiredUnverifiedAccountsJob`, which is the
      other daily auth sweep. That worker ERASES accounts through the full GDPR
      deletion path; this one flips one boolean on live accounts that keep
      everything. Sharing a retry policy and a partial-failure return between an
      irreversible erasure loop and a reversible flag flip would save one crontab
      line and cost the ability to reason about either.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Accounts

  @impl true
  def perform(_job) do
    ids = Accounts.lapsed_email_change_ids()

    {degraded, failed} =
      Enum.reduce(ids, {0, 0}, fn id, {ok, err} ->
        case Accounts.degrade_lapsed_email_change(id) do
          {:ok, _user} ->
            {ok + 1, err}

          {:error, reason} ->
            Logger.error("ExpiredEmailChangesJob: could not degrade #{id}: #{inspect(reason)}")

            {ok, err + 1}
        end
      end)

    Logger.info(
      "ExpiredEmailChangesJob: degraded #{degraded} account(s) on an unanswered email change, #{failed} failed"
    )

    :telemetry.execute(
      [:stacks, :accounts, :email_change_lapsed],
      %{degraded: degraded, failed: failed},
      %{}
    )

    if failed > 0, do: {:error, :partial_failure}, else: :ok
  end
end
