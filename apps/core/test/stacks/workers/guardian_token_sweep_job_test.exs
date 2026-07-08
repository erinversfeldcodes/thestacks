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

  alias Core.Repo
  alias Stacks.Workers.GuardianTokenSweepJob

  # Inserts a raw row into op.guardian_tokens. exp is a unix timestamp (bigint),
  # matching Guardian.DB.Token's schema. We insert schemalessly because the
  # project has no app-owned Ecto schema for this Guardian.DB-backed table.
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

      # The live token survives; only the expired row is reaped.
      assert remaining_jtis() == ["live-token"]
    end

    test "is a no-op when there are no expired rows" do
      now = Guardian.timestamp()
      insert_token("live-token", now + 8 * 60 * 60)

      assert :ok = perform_job(GuardianTokenSweepJob, %{})

      assert remaining_jtis() == ["live-token"]
    end
  end
end
