defmodule Stacks.Accounts.GuardianDbJwtTest do
  @moduledoc """
  174 — the raw signed bearer must never persist in
  `op.guardian_tokens.jwt`: Guardian.DB stores the full token though
  verify/revoke/purge never read it (verify is jti+aud, purge is exp), so
  a SELECT-capable compromise would yield replayable sessions. Asserts
  the column is stored redacted and the auth flows still work without it.
  """

  use Core.DataCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.Guardian

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

      assert row.jwt == nil,
             "expected persisted jwt to be nil, got #{inspect(row.jwt)} — a replayable bearer token is stored in op.guardian_tokens"

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
              sub: insert(:user).id,
              exp: future_exp,
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

      refute read_token_row(jti), "row should be deleted after revoke"

      assert {:error, _reason} = Guardian.decode_and_verify(token)
    end
  end
end
