defmodule Stacks.ReleaseTest do
  @moduledoc """
  Tests for `Stacks.Release.seed_prod/0` — the production owner-user seed.

  These tests manipulate `PROD_OWNER_EMAIL` and `PROD_OWNER_PASSWORD` via
  `System.put_env/2`/`System.delete_env/1`. Each test snapshots and restores
  prior env var values via `on_exit/1` so tests stay independent.
  """
  use Core.DataCase, async: false

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

      # Password must verify via Argon2 (same check used by Accounts.authenticate/2)
      assert Argon2.verify_pass(password, user.password_hash)
    end

    test "email is normalised (downcased) when stored" do
      email = "Prod-Mixed-Case@Stacks.Test"
      password = "correct-horse-battery-staple"

      System.put_env(@email_var, email)
      System.put_env(@password_var, password)

      assert :ok = Release.seed_prod()

      # Looking up by the downcased form must find the user.
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

      # Call again — must not error, must not change password hash.
      assert :ok = Release.seed_prod()

      user_after = Accounts.get_user_by_email(email)
      assert %User{} = user_after
      assert user_after.id == user_before.id
      assert user_after.password_hash == hash_before

      # And only one row exists for that email.
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

      # Must NOT have inserted a user.
      assert Accounts.get_user_by_email(email) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp from_user_by_email_query(email) do
    import Ecto.Query
    from(u in User, where: u.email == ^email)
  end
end
