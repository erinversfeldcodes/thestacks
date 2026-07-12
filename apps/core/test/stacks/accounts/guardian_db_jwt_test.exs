defmodule Stacks.Accounts.GuardianDbJwtTest do
  @moduledoc """
  Issue #174 — the raw signed bearer token must never persist in
  `op.guardian_tokens.jwt`.

  Guardian.DB tracks every issued "access" token in `op.guardian_tokens` so that
  logout/revoke and per-request verification work server-side (Issue #124, A2).
  The `jwt` column, however, stores the FULL signed bearer token even though the
  verify/revoke/purge path never reads it (verify is by `jti` PK + `aud`, purge is
  by `exp`). A SELECT-capable compromise of that table therefore yields directly
  replayable sessions.

  The fix (a LATER step) installs a `BEFORE INSERT OR UPDATE` trigger on
  `op.guardian_tokens` that forces `NEW.jwt = NULL`, plus a one-time scrub of
  existing rows. These tests pin that invariant at the DB layer:

    * tests 1 & 2 are the RED signal — they fail against the current code because
      the app still persists the raw token (INSERT) and a raw UPDATE value sticks;
    * test 3 is a regression guard — the four Guardian.DB hooks must keep working
      with `jwt` nulled (they already do today, since none of them read `jwt`).

  Raw-table access is schemaless (`Repo.insert_all` / `Repo.all(from … in
  "guardian_tokens" …, prefix: "op")`) because the project owns no Ecto schema for
  this Guardian.DB-backed table — mirroring `guardian_token_sweep_job_test.exs`.
  """

  use Core.DataCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.Guardian

  # Reads a single persisted guardian_tokens row schemalessly, projecting the
  # bookkeeping columns plus the sensitive jwt so we can assert on each.
  defp read_token_row(jti) do
    Repo.one(
      from(t in "guardian_tokens",
        prefix: "op",
        where: t.jti == ^jti,
        select: %{
          jti: t.jti,
          aud: t.aud,
          sub: t.sub,
          exp: t.exp,
          jwt: t.jwt
        }
      )
    )
  end

  describe "jwt is not persisted on INSERT (login path)" do
    test "after encode_and_sign the persisted row has jwt = NULL but keeps its bookkeeping columns" do
      user = insert(:user)

      {:ok, _token, claims} = Guardian.encode_and_sign(user)
      jti = claims["jti"]

      row = read_token_row(jti)

      assert row, "expected a persisted op.guardian_tokens row for jti #{jti}"

      # RED today: the app writes jwt = token, so this is a non-nil signed token.
      assert row.jwt == nil,
             "expected persisted jwt to be nil, got #{inspect(row.jwt)} — a replayable bearer token is stored in op.guardian_tokens"

      # Prove we nulled ONLY the jwt: the columns verify/revoke/sweep actually use
      # must still be populated, or we'd have broken tracking instead of hardening it.
      assert row.jti == jti
      assert row.aud == claims["aud"]
      assert row.sub == to_string(user.id)
      assert is_integer(row.exp)
    end
  end

  describe "jwt is not persisted on UPDATE" do
    test "a raw UPDATE that sets jwt to a token value is forced back to NULL" do
      jti = "jwt-update-#{System.unique_integer([:positive])}"
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      future_exp = System.system_time(:second) + 8 * 60 * 60

      {1, _} =
        Repo.insert_all(
          "guardian_tokens",
          [
            %{
              jti: jti,
              aud: "access",
              typ: "access",
              sub: Ecto.UUID.generate(),
              exp: future_exp,
              # Even the initial insert value must not survive the trigger, but the
              # UPDATE below is the specific behaviour under test here.
              jwt: "raw.token.value",
              inserted_at: now,
              updated_at: now
            }
          ],
          prefix: "op"
        )

      {1, _} =
        Repo.update_all(
          from(t in "guardian_tokens", prefix: "op", where: t.jti == ^jti),
          set: [jwt: "another.raw.token"]
        )

      row = read_token_row(jti)

      assert row, "expected the raw guardian_tokens row to still exist after UPDATE"

      # RED today: no trigger, so the UPDATE value "another.raw.token" persists.
      assert row.jwt == nil,
             "expected jwt to be nil after UPDATE, got #{inspect(row.jwt)} — the trigger does not cover UPDATE"
    end
  end

  describe "no #124-A2 regression — the four Guardian.DB hooks still work with jwt nulled" do
    test "a freshly issued token verifies (after_encode_and_sign + on_verify)" do
      user = insert(:user)

      {:ok, token, _claims} = Guardian.encode_and_sign(user)
      assert {:ok, _claims} = Guardian.decode_and_verify(token)
    end

    test "revoke deletes the row and the token no longer verifies (on_revoke)" do
      user = insert(:user)

      {:ok, token, claims} = Guardian.encode_and_sign(user)
      jti = claims["jti"]

      assert read_token_row(jti), "row should exist before revoke"

      assert {:ok, _claims} = Guardian.revoke(token)

      # Row is gone …
      refute read_token_row(jti), "row should be deleted after revoke"

      # … and because the token is no longer tracked, verification fails.
      assert {:error, _reason} = Guardian.decode_and_verify(token)
    end

    # Expired-token sweeping is already covered by
    # apps/core/test/stacks/workers/guardian_token_sweep_job_test.exs — not
    # duplicated here.
  end
end
