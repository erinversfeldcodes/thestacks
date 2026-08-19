defmodule Stacks.AccountsSignupReapTest do
  @moduledoc """
      Registration reaps abandoned signups, so erasing them does not depend on a nightly job.

      `ExpiredUnverifiedAccountsJob` was the only thing doing this, which made a cron entry
      the sole guarantee for a retention obligation — and nothing user-triggered could
      substitute, because whoever abandoned a signup never comes back. With the platform
      scaling to zero that job may not fire at all.
  """

  use Core.DataCase, async: false

  import Ecto.Query

  alias Stacks.Accounts
  alias Stacks.Accounts.User

  # An abandoned signup as registration actually leaves one: unconfirmed AND
  # holding the token registration minted for it, signed when the account was
  # created. Without the token this is not a signup at all — it is the shape an
  # account takes when its email change lapsed, which the reaper must never touch.
  defp unconfirmed(email, created_at) do
    id = Ecto.UUID.generate()

    Core.Repo.insert!(%User{
      id: id,
      email: email,
      display_name: "Abandoned",
      handle: "abandoned_#{System.unique_integer([:positive])}",
      password_hash: Argon2.hash_pwd_salt("whatever"),
      role: "user",
      email_confirmed: false,
      email_confirmation_token:
        Phoenix.Token.sign(CoreWeb.Endpoint, "email_confirm", id,
          signed_at: DateTime.to_unix(created_at)
        ),
      created_at: created_at,
      updated_at: created_at
    })
  end

  defp exists?(id), do: Core.Repo.exists?(from u in User, where: u.id == ^id)

  defp valid_attrs(email) do
    %{email: email, password: "sufficiently-long-password", display_name: "New Person"}
  end

  describe "re-registering an address someone abandoned" do
    test "erases the abandoned account so the address is usable" do
      long_ago = DateTime.add(DateTime.utc_now(), -30, :day)
      old = unconfirmed("reclaim@example.test", long_ago)

      assert {:ok, fresh} = Accounts.register(valid_attrs("reclaim@example.test"))

      refute exists?(old.id), "the abandoned account should have been erased"
      refute fresh.id == old.id
      assert fresh.email == "reclaim@example.test"
    end

    test "reclaims it regardless of how recent the abandonment was" do
      minutes_ago = DateTime.add(DateTime.utc_now(), -5, :minute)
      recent = unconfirmed("mistyped@example.test", minutes_ago)

      assert {:ok, _} = Accounts.register(valid_attrs("mistyped@example.test"))
      refute exists?(recent.id)
    end

    test "matches the address case-insensitively" do
      old = unconfirmed("MixedCase@Example.test", DateTime.add(DateTime.utc_now(), -2, :day))

      assert {:ok, _} = Accounts.register(valid_attrs("mixedcase@example.test"))
      refute exists?(old.id)
    end

    test "leaves a confirmed account alone, so the address stays taken" do
      confirmed =
        Core.Repo.insert!(%User{
          email: "real@example.test",
          display_name: "Real Person",
          handle: "real_person_#{System.unique_integer([:positive])}",
          password_hash: Argon2.hash_pwd_salt("whatever"),
          role: "user",
          email_confirmed: true,
          created_at: DateTime.add(DateTime.utc_now(), -100, :day),
          updated_at: DateTime.utc_now()
        })

      assert {:error, changeset} = Accounts.register(valid_attrs("real@example.test"))
      assert errors_on(changeset)[:email]
      assert exists?(confirmed.id), "a confirmed account must survive"
    end
  end

  describe "reaping unrelated debt" do
    test "erases other expired unverified accounts opportunistically" do
      long_ago = DateTime.add(DateTime.utc_now(), -30, :day)
      stale = unconfirmed("someone-else@example.test", long_ago)

      assert {:ok, _} = Accounts.register(valid_attrs("brand-new@example.test"))

      refute exists?(stale.id)
    end

    test "leaves an unverified account still inside its TTL" do
      just_now = DateTime.add(DateTime.utc_now(), -1, :minute)
      pending = unconfirmed("still-deciding@example.test", just_now)

      assert {:ok, _} = Accounts.register(valid_attrs("brand-new2@example.test"))

      assert exists?(pending.id), "an unverified account inside its TTL must survive"
    end

    test "a registration still succeeds when reaping cannot" do
      assert {:ok, _} = Accounts.register(valid_attrs("unaffected@example.test"))
    end
  end
end
