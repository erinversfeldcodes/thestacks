defmodule Stacks.ReleaseOperatorRecoveryTest do
  @moduledoc """
      `Stacks.Release.recover_operator_access/1` — the path that lets a platform
      operator get back in when session transport fails.

      ⛔ WHY IT EXISTS. Moving the session from a bearer token the client held to
      an `HttpOnly` cookie the server sets can lock the owner out of production,
      and nothing restored operator access: the only operator tasks were the GDPR
      erase and lookup, neither of which touches sessions. A refused cookie is
      indistinguishable from being signed out — nothing readable in the browser
      tells the two apart. The
      interim path was accidental — while both transports were accepted, an
      operator holding a bearer token could still reach the API — which is also
      exactly why the bearer deletion must not land before this.

      ⚖️ **ITS GUARD IS DELIBERATELY WEAKER THAN `seed_live/0`'s, and the
      asymmetry is the point.** Seeding production is never correct, so that gate
      is an env production never carries. Recovering an operator IS correct on
      production — it is the only place the lockout matters — so a gate production
      could not satisfy would make the task useless exactly when it is needed.
      `STACKS_OPERATOR_RECOVERY=1` is set on the invocation instead, so the task
      cannot fire from a stray `rpc` in a script but can always be run by someone
      who means to.
  """
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.Audit.Entry
  alias Stacks.Release

  @flag "STACKS_OPERATOR_RECOVERY"

  setup do
    original = System.get_env(@flag)

    on_exit(fn ->
      case original do
        nil -> System.delete_env(@flag)
        value -> System.put_env(@flag, value)
      end
    end)

    :ok
  end

  defp params(overrides) do
    %{"email" => "owner@example.com", "actor" => "owner", "reason" => "locked out"}
    |> Map.merge(overrides)
    |> Jason.encode!()
    |> Base.encode64()
  end

  defp a_locked_out_operator do
    user = insert(:user, email: "owner@example.com")

    {:ok, _family} =
      Accounts.rotate_token_family(%{
        family_id: Ecto.UUID.generate(),
        user_id: user.id,
        current_jti: Ecto.UUID.generate(),
        session_started_at: DateTime.utc_now()
      })

    user
  end

  describe "the guard" do
    test "refuses without the env set" do
      System.delete_env(@flag)

      error = assert_raise RuntimeError, fn -> Release.recover_operator_access(params(%{})) end

      assert error.message =~ "STACKS_OPERATOR_RECOVERY"
      assert error.message =~ "deliberate"
    end

    # ⛔ ASSERTS THE MESSAGE, NOT MERELY THAT SOMETHING RAISED — and a probe is
    # what showed why. Written first as a bare `assert_raise RuntimeError`, it
    # stayed GREEN with the guard neutered: the task then reached the lookup and
    # raised "no user with that email" instead, since this case inserts nobody.
    # A test that cannot tell which refusal it got is satisfied by the wrong one.
    test "refuses when the env is set to something other than \"1\"" do
      System.put_env(@flag, "true")

      error = assert_raise RuntimeError, fn -> Release.recover_operator_access(params(%{})) end

      assert error.message =~ "STACKS_OPERATOR_RECOVERY"
    end
  end

  describe "with the guard satisfied" do
    setup do
      System.put_env(@flag, "1")
      :ok
    end

    test "revokes every live session family for the operator" do
      user = a_locked_out_operator()

      # ⛔ ANTI-VACUITY, and it is the half that makes this mean anything: the
      # family must be LIVE first. Without it the assertion below passes against
      # a user who never had a session, which is indistinguishable from one whose
      # sessions were revoked.
      live_before =
        AuthTokenFamily
        |> where([f], f.user_id == ^user.id and is_nil(f.revoked_at))
        |> Repo.aggregate(:count, :family_id)

      assert live_before == 1

      assert :ok = Release.recover_operator_access(params(%{}))

      live_after =
        AuthTokenFamily
        |> where([f], f.user_id == ^user.id and is_nil(f.revoked_at))
        |> Repo.aggregate(:count, :family_id)

      assert live_after == 0
    end

    test "writes an audit row naming the ACTOR, not only the subject" do
      user = a_locked_out_operator()

      assert :ok =
               Release.recover_operator_access(
                 params(%{"actor" => "erin", "reason" => "cookie transport failed"})
               )

      row =
        Entry
        |> where([a], a.user_id == ^user.id and a.action == "operator.access_recovered")
        |> Repo.one()

      assert row

      # ⛔ THE ACTOR IS THE POINT. A row saying only "this account's sessions were
      # revoked" cannot answer the question an auditor asks, which is who did it.
      #
      # ⚠️ `metadata` is a Cloak-encrypted `:binary` column, so it must be
      # DECRYPTED to be asserted on. A test comparing the raw field would pass
      # against ciphertext that contains anything at all.
      assert {:ok, json} = Stacks.Vault.decrypt(row.metadata)
      assert %{"actor" => "erin", "reason" => "cookie transport failed"} = Jason.decode!(json)
    end

    test "refuses an unknown email rather than silently doing nothing" do
      error =
        assert_raise RuntimeError, fn ->
          Release.recover_operator_access(params(%{"email" => "nobody@example.com"}))
        end

      assert error.message =~ "no user with that email"
    end

    # ⚠️ Each required field separately, because a single "it validates input"
    # case passes while two of the three go unchecked — and `actor` is the one
    # that matters most: without it the audit row cannot name who acted, which is
    # the whole reason the row exists.
    for {field, value} <- [{"email", ""}, {"actor", ""}, {"reason", ""}] do
      test "refuses when #{field} is blank" do
        assert_raise RuntimeError, fn ->
          Release.recover_operator_access(params(%{unquote(field) => unquote(value)}))
        end
      end
    end
  end
end
