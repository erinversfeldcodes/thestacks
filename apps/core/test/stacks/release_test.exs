defmodule Stacks.ReleaseTest do
  @moduledoc """
      Tests for `Stacks.Release.seed_prod/0` — the production owner-user seed.

      These tests manipulate `PROD_OWNER_EMAIL` and `PROD_OWNER_PASSWORD` via
      `System.put_env/2`/`System.delete_env/1`. Each test snapshots and restores
      prior env var values via `on_exit/1` so tests stay independent.
  """
  use Core.DataCase, async: false

  import ExUnit.CaptureIO
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.User
  alias Stacks.Release

  @email_var "PROD_OWNER_EMAIL"
  @password_var "PROD_OWNER_PASSWORD"

  setup do
    prior_email = System.get_env(@email_var)
    prior_password = System.get_env(@password_var)

    on_exit(fn ->
      restore_env(@email_var, prior_email)
      restore_env(@password_var, prior_password)
    end)

    :ok
  end

  defp restore_env(var, nil), do: System.delete_env(var)
  defp restore_env(var, value), do: System.put_env(var, value)

  describe "seed_prod/0 env var validation" do
    test "raises when PROD_OWNER_EMAIL is missing" do
      System.delete_env(@email_var)
      System.put_env(@password_var, "long-enough-pw")

      assert_raise RuntimeError, ~r/PROD_OWNER_EMAIL/, fn ->
        Release.seed_prod()
      end
    end

    test "raises when PROD_OWNER_EMAIL is empty" do
      System.put_env(@email_var, "")
      System.put_env(@password_var, "long-enough-pw")

      assert_raise RuntimeError, ~r/PROD_OWNER_EMAIL/, fn ->
        Release.seed_prod()
      end
    end

    test "raises when PROD_OWNER_PASSWORD is missing" do
      System.put_env(@email_var, "owner@stacks.test")
      System.delete_env(@password_var)

      assert_raise RuntimeError, ~r/PROD_OWNER_PASSWORD/, fn ->
        Release.seed_prod()
      end
    end

    test "raises when PROD_OWNER_PASSWORD is empty" do
      System.put_env(@email_var, "owner@stacks.test")
      System.put_env(@password_var, "")

      assert_raise RuntimeError, ~r/PROD_OWNER_PASSWORD/, fn ->
        Release.seed_prod()
      end
    end
  end

  describe "seed_prod/0 owner creation" do
    test "creates an owner user with the given credentials when none exists" do
      email = "prod-owner-create@stacks.test"
      password = "correct-horse-battery-staple"

      System.put_env(@email_var, email)
      System.put_env(@password_var, password)

      assert :ok = Release.seed_prod()

      user = Accounts.get_user_by_email(email)
      assert %User{} = user
      assert user.email == email
      assert user.role == "owner"

      assert Argon2.verify_pass(password, user.password_hash)
    end

    test "email is normalised (downcased) when stored" do
      email = "Prod-Mixed-Case@Stacks.Test"
      password = "correct-horse-battery-staple"

      System.put_env(@email_var, email)
      System.put_env(@password_var, password)

      assert :ok = Release.seed_prod()

      user = Accounts.get_user_by_email(String.downcase(email))
      assert %User{} = user
      assert user.email == String.downcase(email)
    end
  end

  describe "seed_prod/0 idempotency" do
    test "is idempotent — second call does not create a duplicate" do
      email = "prod-owner-idem@stacks.test"
      password = "correct-horse-battery-staple"

      System.put_env(@email_var, email)
      System.put_env(@password_var, password)

      assert :ok = Release.seed_prod()
      user_before = Accounts.get_user_by_email(email)
      assert %User{} = user_before
      hash_before = user_before.password_hash

      assert :ok = Release.seed_prod()

      user_after = Accounts.get_user_by_email(email)
      assert %User{} = user_after
      assert user_after.id == user_before.id
      assert user_after.password_hash == hash_before

      assert Repo.aggregate(from_user_by_email_query(email), :count, :id) == 1
    end
  end

  describe "seed_prod/0 password validation" do
    test "rejects a password below the minimum length without inserting a user" do
      email = "prod-owner-shortpw@stacks.test"

      System.put_env(@email_var, email)
      System.put_env(@password_var, "x")

      assert_raise RuntimeError, fn ->
        Release.seed_prod()
      end

      assert Accounts.get_user_by_email(email) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 1 — seed_prober/0
  #
  # `seed_prober/0` is the production-safe seed for the dedicated probe
  # user. Mirrors `seed_prod/0`'s shape but creates a non-owner user so the
  # probe-production.sh credentials never carry owner privileges. Reads
  # `STACKS_PROBER_EMAIL` / `STACKS_PROBER_PASSWORD` from the environment.
  #
  # Invariants under test:
  #   - Idempotent — second call no-ops on existing user, doesn't rotate
  #     password or change role.
  #   - Creates a user with role: "user" (NOT "owner") and
  #     email_confirmed: true so the probe's first login attempt doesn't
  #     get email_unconfirmed.
  #   - Raises RuntimeError when env vars are missing (mirrors seed_prod).
  #
  # Until the function exists, every test fails with
  # `(UndefinedFunctionError) function Stacks.Release.seed_prober/0 is
  # undefined or private`.
  # ---------------------------------------------------------------------------

  @prober_email_var "STACKS_PROBER_EMAIL"
  @prober_password_var "STACKS_PROBER_PASSWORD"

  defp setup_prober_env(email, password) do
    prior_email = System.get_env(@prober_email_var)
    prior_password = System.get_env(@prober_password_var)

    if email == :delete do
      System.delete_env(@prober_email_var)
    else
      System.put_env(@prober_email_var, email)
    end

    if password == :delete do
      System.delete_env(@prober_password_var)
    else
      System.put_env(@prober_password_var, password)
    end

    ExUnit.Callbacks.on_exit(fn ->
      restore_env(@prober_email_var, prior_email)
      restore_env(@prober_password_var, prior_password)
    end)

    :ok
  end

  describe "seed_prober/0 env var validation" do
    test "raises when STACKS_PROBER_EMAIL is missing" do
      setup_prober_env(:delete, "long-enough-pw")

      assert_raise RuntimeError, ~r/STACKS_PROBER_EMAIL/, fn ->
        Release.seed_prober()
      end
    end

    test "raises when STACKS_PROBER_EMAIL is empty" do
      setup_prober_env("", "long-enough-pw")

      assert_raise RuntimeError, ~r/STACKS_PROBER_EMAIL/, fn ->
        Release.seed_prober()
      end
    end

    test "raises when STACKS_PROBER_PASSWORD is missing" do
      setup_prober_env("prober@thestacks.app", :delete)

      assert_raise RuntimeError, ~r/STACKS_PROBER_PASSWORD/, fn ->
        Release.seed_prober()
      end
    end

    test "raises when STACKS_PROBER_PASSWORD is empty" do
      setup_prober_env("prober@thestacks.app", "")

      assert_raise RuntimeError, ~r/STACKS_PROBER_PASSWORD/, fn ->
        Release.seed_prober()
      end
    end
  end

  describe "seed_prober/0 user creation" do
    test "creates prober@thestacks.app with role :user and email_confirmed: true" do
      email = "prober-create@stacks.test"
      password = "correct-horse-battery-staple"

      setup_prober_env(email, password)

      assert :ok = Release.seed_prober()

      user = Accounts.get_user_by_email(email)
      assert %User{} = user
      assert user.email == email
      assert user.role == "user", "prober must have role 'user' (NOT 'owner')"
      assert user.email_confirmed == true
      assert Argon2.verify_pass(password, user.password_hash)
    end

    test "email is normalised (downcased) when stored" do
      email = "Prober-Mixed-Case@Stacks.Test"
      password = "correct-horse-battery-staple"

      setup_prober_env(email, password)

      assert :ok = Release.seed_prober()

      user = Accounts.get_user_by_email(String.downcase(email))
      assert %User{} = user
      assert user.email == String.downcase(email)
      assert user.role == "user"
    end
  end

  describe "seed_prober/0 idempotency" do
    test "is idempotent — second call does not create a duplicate or rotate the password" do
      email = "prober-idem@stacks.test"
      password = "correct-horse-battery-staple"

      setup_prober_env(email, password)

      assert :ok = Release.seed_prober()
      user_before = Accounts.get_user_by_email(email)
      assert %User{} = user_before
      hash_before = user_before.password_hash

      assert :ok = Release.seed_prober()

      user_after = Accounts.get_user_by_email(email)
      assert %User{} = user_after
      assert user_after.id == user_before.id
      assert user_after.password_hash == hash_before
      assert user_after.role == "user"

      assert Repo.aggregate(from_user_by_email_query(email), :count, :id) == 1
    end
  end

  describe "gdpr_erase_user/1 dry run (user_id only)" do
    test "previews by user_id without deleting" do
      user = insert(:user, email: "erase-dry@stacks.test", handle: "erase_dry")

      out =
        capture_io(fn ->
          assert :ok = Release.gdpr_erase_user(encode(%{user_id: user.id}))
        end)

      assert out =~ "GDPR_ERASE_RESOLVED user_id=#{user.id}"
      assert out =~ "GDPR_ERASE_PREVIEW"
      assert out =~ "GDPR_ERASE_RESULT dry_run"
      assert Accounts.get_user(user.id), "dry run must not delete"
    end
  end

  describe "gdpr_erase_user/1 execute (user_id only)" do
    test "deletes the user when execute + matching confirm + reason are present" do
      user = insert(:user, email: "erase-go@stacks.test", handle: "erase_go")
      insert(:bookshelf, user: user)

      out =
        capture_io(fn ->
          assert :ok =
                   Release.gdpr_erase_user(
                     encode(%{
                       user_id: user.id,
                       execute: true,
                       confirm: user.id,
                       reason: "verified erasure request"
                     })
                   )
        end)

      assert out =~ "GDPR_ERASE_RESULT deleted"
      assert Accounts.get_user(user.id) == nil
    end

    test "raises and preserves the user when confirm does not match the user_id" do
      user = insert(:user, email: "erase-nomatch@stacks.test", handle: "erase_nomatch")

      assert_raise RuntimeError, ~r/confirmation does not match/, fn ->
        capture_io(fn ->
          Release.gdpr_erase_user(
            encode(%{
              user_id: user.id,
              execute: true,
              confirm: Ecto.UUID.generate(),
              reason: "x"
            })
          )
        end)
      end

      assert Accounts.get_user(user.id)
    end

    test "raises when execute is set but reason is blank" do
      user = insert(:user, email: "erase-noreason@stacks.test", handle: "erase_noreason")

      assert_raise RuntimeError, ~r/reason is required/, fn ->
        capture_io(fn ->
          Release.gdpr_erase_user(encode(%{user_id: user.id, execute: true, confirm: user.id}))
        end)
      end

      assert Accounts.get_user(user.id)
    end
  end

  describe "gdpr_erase_user/1 refuses ambiguous / invalid input" do
    test "raises on a non-UUID identifier (no email/handle resolution)" do
      user = insert(:user, email: "erase-byemail@stacks.test", handle: "erase_byemail")

      assert_raise RuntimeError, ~r/not a valid UUID/, fn ->
        capture_io(fn ->
          Release.gdpr_erase_user(encode(%{user_id: user.email}))
        end)
      end

      assert Accounts.get_user(user.id), "an email must never resolve in the erase path"
    end

    test "raises when the user_id is a valid UUID but no such user exists" do
      assert_raise RuntimeError, ~r/no user exists/, fn ->
        capture_io(fn ->
          Release.gdpr_erase_user(encode(%{user_id: Ecto.UUID.generate()}))
        end)
      end
    end

    test "raises when user_id is missing" do
      assert_raise RuntimeError, ~r/user_id is required/, fn ->
        capture_io(fn -> Release.gdpr_erase_user(encode(%{reason: "x"})) end)
      end
    end
  end

  describe "gdpr_lookup_user/1 (email/handle → user_id, read-only)" do
    test "finds a user however the operator cased the email" do
      user = insert(:user, email: "dup@stacks.test", handle: "dup_one")

      out =
        capture_io(fn ->
          assert :ok = Release.gdpr_lookup_user(encode(%{query: "DUP@Stacks.Test"}))
        end)

      assert out =~ "user_id=#{user.id}"
      assert out =~ "GDPR_LOOKUP_COUNT 1"
    end

    test "finds a user by unique handle" do
      user = insert(:user, email: "byhandle@stacks.test", handle: "lookup_handle")

      out =
        capture_io(fn ->
          assert :ok = Release.gdpr_lookup_user(encode(%{query: "lookup_handle"}))
        end)

      assert out =~ "user_id=#{user.id}"
      assert out =~ "GDPR_LOOKUP_COUNT 1"
    end

    test "reports zero matches for an unknown query without raising" do
      out =
        capture_io(fn ->
          assert :ok = Release.gdpr_lookup_user(encode(%{query: "ghost@stacks.test"}))
        end)

      assert out =~ "GDPR_LOOKUP_COUNT 0"
    end
  end

  defp encode(params), do: params |> Jason.encode!() |> Base.encode64()

  defp from_user_by_email_query(email) do
    import Ecto.Query
    from(u in User, where: u.email == ^email)
  end
end
