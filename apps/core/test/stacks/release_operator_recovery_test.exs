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
      A confirmation carried IN THE PAYLOAD does that job instead, so the task
      cannot fire from a stray `rpc` in a script but can always be run by someone
      who means to.

      ⛔ It is not an environment variable, and the reason is measured: `rpc`
      evaluates inside the already-running node, which does not see the invoking
      shell's environment. Every test here once passed against an env guard that
      could never be satisfied in production, because `System.put_env` in a test
      process IS visible to the code under test.
  """
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.Audit.Entry
  alias Stacks.Release

  @flag "STACKS_OPERATOR_RECOVERY"
  @confirm "yes-recover-this-operator"

  defp params(overrides) do
    %{
      "email" => "owner@example.com",
      "actor" => "owner",
      "reason" => "locked out",
      "confirm" => @confirm
    }
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
    test "refuses without the confirmation" do
      error =
        assert_raise RuntimeError, fn ->
          Release.recover_operator_access(params(%{"confirm" => nil}))
        end

      assert error.message =~ "refusing to recover operator access"
      assert error.message =~ @confirm
    end

    # ⛔ ASSERTS THE MESSAGE, NOT MERELY THAT SOMETHING RAISED — and a probe is
    # what showed why. Written first as a bare `assert_raise RuntimeError`, it
    # stayed GREEN with the guard neutered: the task then reached the lookup and
    # raised "no user with that email" instead, since this case inserts nobody.
    # A test that cannot tell which refusal it got is satisfied by the wrong one.
    test "refuses a confirmation that is nearly right" do
      error =
        assert_raise RuntimeError, fn ->
          Release.recover_operator_access(params(%{"confirm" => "yes"}))
        end

      assert error.message =~ "refusing to recover operator access"
    end

    # ⛔ THE CASE THAT WOULD HAVE CAUGHT A GUARD NOTHING COULD SATISFY.
    #
    # This guard used to be `System.get_env("STACKS_OPERATOR_RECOVERY") == "1"`.
    # Every test here passed, because `System.put_env` in a test process is
    # visible to the code under test. In production it is not: the documented
    # transport is `rpc`, which evaluates inside the ALREADY-RUNNING node, and
    # that node never sees the invoking shell's environment.
    #
    # ⚠️ PROVEN on a deployed stack, 2026-11-07: with the variable set,
    # `printenv` in the invoking shell read `1` while `System.get_env(...)`
    # evaluated inside the node read **nil**. The recovery path refused every
    # time, and the suite was green throughout.
    test "the environment variable is NOT the guard, however it is set" do
      System.put_env(@flag, "1")
      on_exit(fn -> System.delete_env(@flag) end)

      error =
        assert_raise RuntimeError, fn ->
          Release.recover_operator_access(params(%{"confirm" => nil}))
        end

      assert error.message =~ "refusing to recover operator access",
             "setting the env must not satisfy the guard — it cannot cross the rpc boundary"

      assert error.message =~ "rpc",
             "the refusal must explain why an env var will not work here, or the next " <>
               "operator will spend the outage setting one"
    end

    # ⛔ THE RUNBOOK'S OWN EXAMPLE PAYLOAD USED TO FAIL HERE. `base64` wraps at
    # 76 columns, and the documented `{"email":…,"actor":…,"reason":…}` encodes
    # to TWO lines — which a bare `Base.decode64!/1` rejects. An operator
    # following the instructions verbatim got an ArgumentError instead of their
    # account back.
    test "accepts a payload that base64 wrapped across lines" do
      user = a_locked_out_operator()

      wrapped =
        %{
          "email" => user.email,
          "actor" => "owner",
          "reason" => "cookie transport refused after deploy",
          "confirm" => @confirm
        }
        |> Jason.encode!()
        |> Base.encode64()
        |> String.codepoints()
        |> Enum.chunk_every(76)
        |> Enum.map_join("\n", &Enum.join/1)

      assert String.contains?(wrapped, "\n"), "the fixture must actually be wrapped"
      assert :ok = Release.recover_operator_access(wrapped)
    end
  end

  describe "with the guard satisfied" do
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

  # ⛔ THE CLASS, NOT JUST THE INSTANCE ABOVE. Every release task takes
  # Base64(JSON) on the rpc boundary, and `base64` wraps at 76 columns — so each
  # one whose documented payload exceeds that length fails to decode for an
  # operator following its runbook verbatim. The recovery task was the instance
  # that surfaced it; `gdpr_erase_user/1` and `gdpr_lookup_user/1` had it too,
  # and a GDPR erasure an operator cannot invoke is a compliance problem rather
  # than an inconvenience.
  #
  # ⚠️ Asserted over the SOURCE because the alternative is one fixture per task
  # and a new gap each time a task is added — the population is "every
  # `Base.decode64!` in this module", and that is what is checked.
  describe "every release task tolerates a wrapped payload" do
    test "no Base.decode64! in Stacks.Release is whitespace-strict" do
      path = Path.expand("../../lib/stacks/release.ex", __DIR__)

      # ⚠️ Loudly, not silently: a path that drifts makes this assertion vacuous
      # by reading nothing, and a gate that reads nothing passes.
      assert File.exists?(path), "expected Stacks.Release at #{path}; fix this path if it moved"

      source = File.read!(path)

      code =
        source
        |> String.split("\n")
        |> Enum.map_join("\n", fn line ->
          if Regex.match?(~r/^\s*#/, line), do: "", else: line
        end)

      assert code =~ "Base.decode64!", "the stripper ate the code it was meant to read"

      strict = Regex.scan(~r/Base\.decode64!\(\s*\)/, code)

      assert strict == [],
             "#{length(strict)} call(s) to Base.decode64!/1 with no `ignore: :whitespace`. " <>
               "`base64` wraps at 76 columns, so a realistic payload arrives with a newline " <>
               "and the task raises ArgumentError at the one moment an operator needs it."
    end
  end
end
