defmodule Stacks.Workers.GuardianTokenSweepJobTest do
  @moduledoc """
  Reaper for the server-side JWT store (Issue #124, A2 — P1 companion).

  `Guardian.revoke/1` deletes a token row on logout, but an access token that
  simply *expires* (its 8h ttl elapses without an explicit logout) leaves a dead
  row behind in `op.guardian_tokens`. Without a periodic sweep the table grows
  unbounded — every session ever issued becomes a permanent tombstone. This job
  runs `Guardian.DB.Token.purge_expired_tokens/0` (a single indexed range delete
  on `exp`) to reclaim them.
  """
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.Workers.GuardianTokenSweepJob

  defp insert_token(jti, exp_unix) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {1, _} =
      Repo.insert_all(
        "guardian_tokens",
        [
          %{
            jti: jti,
            aud: "stacks",
            typ: "access",
            exp: exp_unix,
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: "op"
      )

    :ok
  end

  defp remaining_jtis do
    Repo.all(from(t in "guardian_tokens", prefix: "op", select: t.jti, order_by: t.jti))
  end

  describe "perform/1" do
    test "purges only rows whose exp is in the past" do
      now = Guardian.timestamp()

      insert_token("expired-token", now - 3600)
      insert_token("live-token", now + 8 * 60 * 60)

      assert :ok = perform_job(GuardianTokenSweepJob, %{})

      assert remaining_jtis() == ["live-token"]
    end

    test "is a no-op when there are no expired rows" do
      now = Guardian.timestamp()
      insert_token("live-token", now + 8 * 60 * 60)

      assert :ok = perform_job(GuardianTokenSweepJob, %{})

      assert remaining_jtis() == ["live-token"]
    end

    test "prunes long-revoked and past-cap families but keeps live ones" do
      now = DateTime.utc_now()
      user_id = insert(:user).id

      live = insert_family(user_id, session_started_at: now, revoked_at: nil)

      just_revoked =
        insert_family(user_id,
          session_started_at: DateTime.add(now, -3600, :second),
          revoked_at: now
        )

      long_revoked =
        insert_family(user_id,
          session_started_at: DateTime.add(now, -30 * 86_400, :second),
          revoked_at: DateTime.add(now, -30 * 86_400, :second)
        )

      past_cap =
        insert_family(user_id,
          session_started_at: DateTime.add(now, -60 * 86_400, :second),
          revoked_at: nil
        )

      assert :ok = perform_job(GuardianTokenSweepJob, %{})

      assert Repo.get(AuthTokenFamily, live)
      assert Repo.get(AuthTokenFamily, just_revoked)
      refute Repo.get(AuthTokenFamily, long_revoked)
      refute Repo.get(AuthTokenFamily, past_cap)
    end
  end

  defp insert_family(user_id, opts) do
    {:ok, family} =
      %AuthTokenFamily{}
      |> AuthTokenFamily.changeset(%{
        family_id: Ecto.UUID.generate(),
        user_id: user_id,
        current_jti: "jti-#{System.unique_integer([:positive])}",
        session_started_at: Keyword.fetch!(opts, :session_started_at),
        revoked_at: Keyword.get(opts, :revoked_at)
      })
      |> Repo.insert()

    family.family_id
  end
end
