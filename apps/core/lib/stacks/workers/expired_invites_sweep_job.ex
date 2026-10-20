defmodule Stacks.Workers.ExpiredInvitesSweepJob do
  @moduledoc """
      Daily Oban worker that deletes invitations which expired more than 90 days
      ago AND were never redeemed.

      An unredeemed expired invitation still holds the owner's note and possibly
      an invitee's email address — data about a person who never became a user and
      therefore can never exercise erasure. Nobody can ask for it to go, so the
      platform drops it on a clock — the same reasoning as the 30-day image
      retention sweep. Redeemed invitations are kept (their PII is settled by the
      redeemer's own erasure path) as the beta's issue history.

      Idempotent; standard Oban retry on failure. Scheduled via the crontab in
      `config/config.exs`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Core.Repo
  alias Stacks.Accounts.InviteCode

  @retention_days 90

  @impl true
  def perform(%Oban.Job{}) do
    cutoff = cutoff()

    # Both arms matter. `expires_at` is NULLABLE and a null means "never expires"
    # (`Invites.expires_at_from/1` returns nil for an explicit `"expires_in_days": null`),
    # so the original `not is_nil(expires_at)` guard meant a never-expiring invitation
    # was never swept — and since it was never redeemed either, no erasure path reached
    # it. Its `invited_email` belongs to someone who never registered and therefore
    # cannot ask for it to be removed, which is the case retention exists for.
    #
    # A null-expiry row ages from `created_at` instead, on the same 90-day clock.
    {deleted, _} = Repo.delete_all(sweepable(cutoff))

    Logger.info("ExpiredInvitesSweepJob: deleted #{deleted} expired unredeemed invitation(s)")

    :ok
  end

  @doc """
      How many invitations still match what this job sweeps. Zero after a
      complete run; non-zero means rows remain past retention.

      ⚠️ Shares `sweepable/1` with `perform/1` rather than restating the
      predicate. A monitoring query that restates a sweep's definition of
      "expired" can drift from it, and the direction it drifts is the dangerous
      one: the monitor reports all-clear while the sweep disagrees, so the
      backlog it exists to reveal is exactly what it hides.
  """
  @spec pending_count() :: non_neg_integer()
  def pending_count do
    Repo.aggregate(sweepable(cutoff()), :count)
  end

  defp cutoff, do: DateTime.add(DateTime.utc_now(), -@retention_days * 24 * 3600, :second)

  defp sweepable(cutoff) do
    from(i in InviteCode,
      where:
        (not is_nil(i.expires_at) and i.expires_at < ^cutoff) or
          (is_nil(i.expires_at) and i.created_at < ^cutoff),
      where: is_nil(i.redeemed_at) and i.use_count == 0
    )
  end
end
