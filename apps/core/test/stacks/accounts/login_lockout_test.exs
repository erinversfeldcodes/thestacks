defmodule Stacks.Accounts.LoginLockoutTest do
  @moduledoc """
      Per-account login lockout.

      Verifies the lockout policy in `Stacks.Accounts.authenticate/2`:

      - threshold failures inside the rolling window lock the account
      - locked accounts skip ArgonPool entirely and return:account_locked
      - successful logins reset the counter and clear the lock
      - expired `locked_until` auto-clears
      - repeat lockouts within the backoff window double the duration up to a cap
      - unknown emails go through the constant-time dummy-hash path
  """

  use Core.DataCase, async: false

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.User

  @password "lockout-test-password"

  setup do
    threshold = Application.get_env(:core, :login_lockout_threshold)
    window = Application.get_env(:core, :login_lockout_window_seconds)
    duration = Application.get_env(:core, :login_lockout_duration_seconds)
    max_duration = Application.get_env(:core, :login_lockout_max_duration_seconds)
    backoff = Application.get_env(:core, :login_lockout_backoff_window_seconds)

    Application.put_env(:core, :login_lockout_threshold, 3)
    Application.put_env(:core, :login_lockout_window_seconds, 60)
    Application.put_env(:core, :login_lockout_duration_seconds, 120)
    Application.put_env(:core, :login_lockout_max_duration_seconds, 600)
    Application.put_env(:core, :login_lockout_backoff_window_seconds, 86_400)

    on_exit(fn ->
      Application.put_env(:core, :login_lockout_threshold, threshold)
      Application.put_env(:core, :login_lockout_window_seconds, window)
      Application.put_env(:core, :login_lockout_duration_seconds, duration)
      Application.put_env(:core, :login_lockout_max_duration_seconds, max_duration)
      Application.put_env(:core, :login_lockout_backoff_window_seconds, backoff)
    end)

    :ok
  end

  defp insert_user(email) do
    insert(:user,
      email: email,
      password_hash: Argon2.hash_pwd_salt(@password),
      email_confirmed: true
    )
  end

  describe "failure counter" do
    test "successful login leaves counter at 0" do
      user = insert_user("ok@example.com")
      assert {:ok, _} = Accounts.authenticate(user.email, @password)
      reloaded = Repo.get!(User, user.id)
      assert reloaded.failed_login_count == 0
      assert is_nil(reloaded.locked_until)
    end

    test "wrong password increments the counter" do
      user = insert_user("inc@example.com")
      assert {:error, :invalid_credentials} = Accounts.authenticate(user.email, "wrong")
      reloaded = Repo.get!(User, user.id)
      assert reloaded.failed_login_count == 1
      assert %DateTime{} = reloaded.failed_login_first_at
      assert is_nil(reloaded.locked_until)
    end

    test "under-threshold failures do NOT lock the account" do
      user = insert_user("under@example.com")
      assert {:error, :invalid_credentials} = Accounts.authenticate(user.email, "wrong")
      assert {:error, :invalid_credentials} = Accounts.authenticate(user.email, "wrong")

      reloaded = Repo.get!(User, user.id)
      assert reloaded.failed_login_count == 2
      assert is_nil(reloaded.locked_until)
    end

    test "successful login resets the counter and clears the lock" do
      user = insert_user("reset@example.com")

      _ = Accounts.authenticate(user.email, "wrong")
      _ = Accounts.authenticate(user.email, "wrong")
      assert {:ok, _} = Accounts.authenticate(user.email, @password)

      reloaded = Repo.get!(User, user.id)
      assert reloaded.failed_login_count == 0
      assert is_nil(reloaded.locked_until)
      assert is_nil(reloaded.failed_login_first_at)
    end

    test "expired failure window rolls the counter back to 1" do
      user = insert_user("window@example.com")

      stale = DateTime.add(DateTime.utc_now(), -3_600, :second)

      {1, nil} =
        Repo.update_all(
          User |> Ecto.Query.where([u], u.id == ^user.id),
          set: [failed_login_count: 2, failed_login_first_at: stale]
        )

      assert {:error, :invalid_credentials} = Accounts.authenticate(user.email, "wrong")

      reloaded = Repo.get!(User, user.id)
      assert reloaded.failed_login_count == 1
      assert is_nil(reloaded.locked_until)
    end
  end

  describe "lockout at threshold" do
    test "threshold failures set locked_until in the future" do
      user = insert_user("thresh@example.com")

      Enum.each(1..3, fn _ ->
        Accounts.authenticate(user.email, "wrong")
      end)

      reloaded = Repo.get!(User, user.id)
      assert %DateTime{} = reloaded.locked_until
      assert DateTime.compare(reloaded.locked_until, DateTime.utc_now()) == :gt
    end

    test "subsequent attempts on a locked account return :account_locked with retry_after" do
      user = insert_user("locked@example.com")

      Enum.each(1..3, fn _ ->
        Accounts.authenticate(user.email, "wrong")
      end)

      # The right password must STILL be rejected with :account_locked
      # while locked_until is in the future.
      result = Accounts.authenticate(user.email, @password)
      assert {:error, {:account_locked, retry_after}} = result
      assert is_integer(retry_after)
      assert retry_after > 0
    end

    test "locked attempts do not consume ArgonPool slots" do
      # We assert this by tracing: when locked_until is in the future, the
      # authenticate/2 call must NOT invoke Argon2.verify_pass. We trace
      # the Argon2 module and assert no verify_pass call is made.
      user = insert_user("nopool@example.com")

      Enum.each(1..3, fn _ -> Accounts.authenticate(user.email, "wrong") end)

      :erlang.trace(:all, true, [:call])
      :erlang.trace_pattern({Argon2, :verify_pass, :_}, true, [])

      try do
        Accounts.authenticate(user.email, @password)

        receive do
          {:trace, _, :call, {Argon2, :verify_pass, _}} ->
            flunk("locked account path must not call Argon2.verify_pass/2")
        after
          200 -> :ok
        end
      after
        :erlang.trace_pattern({Argon2, :verify_pass, :_}, false, [])
        :erlang.trace(:all, false, [:call])
      end
    end

    test "lock expires: locked_until in the past is treated as unlocked" do
      user = insert_user("expired@example.com")

      past = DateTime.add(DateTime.utc_now(), -60, :second)

      # The shape a real expired lock has: the window that reached the
      # threshold opened one duration before the lock did. A count without its
      # window start is not a state authenticate/2 can produce, and the trio
      # CHECK on op.users now rejects it.
      {1, nil} =
        Repo.update_all(
          User |> Ecto.Query.where([u], u.id == ^user.id),
          set: [
            locked_until: past,
            failed_login_count: 3,
            failed_login_first_at: DateTime.add(past, -120, :second)
          ]
        )

      assert {:ok, _} = Accounts.authenticate(user.email, @password)
      reloaded = Repo.get!(User, user.id)
      assert is_nil(reloaded.locked_until)
      assert reloaded.failed_login_count == 0
    end
  end

  describe "exponential backoff" do
    test "second lockout within 24h has a longer duration than the first" do
      user = insert_user("backoff@example.com")

      Enum.each(1..3, fn _ -> Accounts.authenticate(user.email, "wrong") end)
      first = Repo.get!(User, user.id)
      first_lock_seconds = DateTime.diff(first.locked_until, DateTime.utc_now())

      # Age the lock out WITHOUT touching the counters. Only a successful login
      # clears them, and it clears `locked_until` in the same statement, so a
      # lock standing over a zeroed counter is a state no login can reach — and
      # the trio CHECK on op.users now says so.
      just_expired = DateTime.add(DateTime.utc_now(), -1, :second)

      {1, nil} =
        Repo.update_all(
          User |> Ecto.Query.where([u], u.id == ^user.id),
          set: [locked_until: just_expired]
        )

      Enum.each(1..3, fn _ -> Accounts.authenticate(user.email, "wrong") end)
      second = Repo.get!(User, user.id)
      second_lock_seconds = DateTime.diff(second.locked_until, DateTime.utc_now())

      assert second_lock_seconds > first_lock_seconds
    end

    test "lockout duration is capped at max_duration_seconds" do
      user = insert_user("cap@example.com")

      # Force a very recent prior lock with a duration already at the cap by
      # placing `locked_until` just in the past with a long failed_login_first_at
      # window — the backoff calculation should clamp at the configured cap.
      # We test this by setting up a long-lived "history" implicitly: drive 6
      # consecutive lockouts and assert the final duration <= max.
      max = Application.get_env(:core, :login_lockout_max_duration_seconds)

      Enum.each(1..6, fn _ ->
        Enum.each(1..3, fn _ -> Accounts.authenticate(user.email, "wrong") end)

        just_expired = DateTime.add(DateTime.utc_now(), -1, :second)

        # Age the lock out only — see the note on the previous test for why the
        # counters are left where the lockout put them.
        Repo.update_all(
          User |> Ecto.Query.where([u], u.id == ^user.id),
          set: [locked_until: just_expired]
        )
      end)

      Enum.each(1..3, fn _ -> Accounts.authenticate(user.email, "wrong") end)
      reloaded = Repo.get!(User, user.id)
      seconds = DateTime.diff(reloaded.locked_until, DateTime.utc_now())
      assert seconds <= max
    end
  end

  describe "constant-time email enumeration defence" do
    test "unknown email exercises constant-time path (timing parity with real verify)" do
      insert(:user,
        email: "timing-known@example.com",
        password_hash: Argon2.hash_pwd_salt("right-pass"),
        email_confirmed: true
      )

      _ = Accounts.authenticate("timing-known@example.com", "wrong-pass")

      {known_us, _} =
        :timer.tc(fn ->
          Accounts.authenticate("timing-known@example.com", "wrong-pass")
        end)

      {unknown_us, _} =
        :timer.tc(fn ->
          Accounts.authenticate("timing-unknown@example.com", "wrong-pass")
        end)

      assert unknown_us > 1_000,
             "unknown-email path returned in #{unknown_us}µs — the dummy " <>
               "Argon2.no_user_verify call appears to be missing (enumeration risk)"

      ratio = unknown_us / max(known_us, 1)

      assert ratio > 0.1 and ratio < 10.0,
             "timing ratio unknown:known = #{ratio} — expected within 10x for " <>
               "constant-time enumeration defence (known=#{known_us}µs, unknown=#{unknown_us}µs)"
    end

    test "unknown email does not crash on the lock check" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate("ghost@example.com", "whatever")
    end
  end
end
