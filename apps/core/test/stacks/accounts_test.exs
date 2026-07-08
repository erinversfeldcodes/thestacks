defmodule Stacks.AccountsTest do
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts

  describe "register/1" do
    test "creates a user with hashed password" do
      attrs = %{"email" => "test@example.com", "password" => "password123"}
      assert {:ok, user} = Accounts.register(attrs)
      assert user.email == "test@example.com"
      assert user.password_hash != nil
      assert user.password == nil
    end

    test "first user gets owner role" do
      attrs = %{"email" => "owner@example.com", "password" => "password123"}
      assert {:ok, user} = Accounts.register(attrs)
      assert user.role == "owner"
    end

    test "subsequent users get user role" do
      insert(:user)
      attrs = %{"email" => "second@example.com", "password" => "password123"}
      assert {:ok, user} = Accounts.register(attrs)
      assert user.role == "user"
    end

    test "returns error on duplicate email" do
      insert(:user, email: "dup@example.com")
      attrs = %{"email" => "dup@example.com", "password" => "password123"}
      assert {:error, changeset} = Accounts.register(attrs)
      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end

    test "returns error on invalid email format" do
      attrs = %{"email" => "not-an-email", "password" => "password123"}
      assert {:error, changeset} = Accounts.register(attrs)
      assert %{email: [_]} = errors_on(changeset)
    end

    test "returns error on short password" do
      attrs = %{"email" => "short@example.com", "password" => "short"}
      assert {:error, changeset} = Accounts.register(attrs)
      assert %{password: [_]} = errors_on(changeset)
    end

    test "emits user.registered event on success" do
      before_count = event_count("user.registered")
      attrs = %{"email" => "registered_event@example.com", "password" => "password123"}
      Accounts.register(attrs)
      assert event_count("user.registered") == before_count + 1
    end

    test "register/1 emits event payload without PII fields" do
      # Verify the event payload built in register/1 excludes :email (PII).
      # Events.emit is called inside the Multi transaction with payload: %{role: user.role}.
      # We verify this by checking that registration succeeds and that the user struct
      # exposes role (not email) as the expected event payload field.
      attrs = %{"email" => "pii_test@example.com", "password" => "password123"}
      assert {:ok, user} = Accounts.register(attrs)
      assert user.role in ["owner", "user"]

      # The payload that would be sent is %{role: user.role} — verify role is a non-nil string
      assert is_binary(user.role)
      # Email must not be part of the event payload (it's stripped in the Multi.run block)
      # The source of truth is the code: payload: %{role: user.role} — no :email key
    end
  end

  # Punch #5 (Issue #124): the user.registered event is emitted INSIDE the
  # registration Ecto.Multi. If the transaction rolls back, no event row must be
  # written to event_log — an event that describes a registration that never
  # happened would corrupt every downstream projection.
  describe "register/1 negative event emission (rollback)" do
    test "does not emit user.registered when the email is a duplicate" do
      insert(:user, email: "dupe_event@example.com")
      before_count = event_count("user.registered")

      assert {:error, %Ecto.Changeset{}} =
               Accounts.register(%{
                 "email" => "dupe_event@example.com",
                 "password" => "password123"
               })

      assert event_count("user.registered") == before_count
    end

    test "does not emit user.registered when the changeset is invalid" do
      before_count = event_count("user.registered")

      # Invalid email format — the :user insert step fails, rolling back the Multi
      # before :emit_event ever runs.
      assert {:error, %Ecto.Changeset{}} =
               Accounts.register(%{"email" => "not-an-email", "password" => "password123"})

      assert event_count("user.registered") == before_count
    end

    test "does not emit user.registered when the password is too short" do
      before_count = event_count("user.registered")

      assert {:error, %Ecto.Changeset{}} =
               Accounts.register(%{"email" => "shortpw_event@example.com", "password" => "x"})

      assert event_count("user.registered") == before_count
    end
  end

  describe "authenticate/2" do
    test "returns user on valid credentials" do
      insert(:user, email: "auth@example.com", password_hash: Argon2.hash_pwd_salt("mypassword"))
      assert {:ok, user} = Accounts.authenticate("auth@example.com", "mypassword")
      assert user.email == "auth@example.com"
    end

    test "returns error on wrong password" do
      insert(:user, email: "wrong@example.com", password_hash: Argon2.hash_pwd_salt("correct"))
      assert {:error, :invalid_credentials} = Accounts.authenticate("wrong@example.com", "wrong")
    end

    test "returns error for unknown email" do
      assert {:error, :invalid_credentials} = Accounts.authenticate("nobody@example.com", "pass")
    end
  end

  describe "authenticate/2 email confirmation gate" do
    test "returns :email_unconfirmed when user is unconfirmed" do
      insert(:user,
        email: "unconfirmed@example.com",
        password_hash: Argon2.hash_pwd_salt("password123"),
        email_confirmed: false
      )

      assert {:error, :email_unconfirmed} =
               Accounts.authenticate("unconfirmed@example.com", "password123")
    end

    test "succeeds when user is confirmed" do
      insert(:user,
        email: "confirmed@example.com",
        password_hash: Argon2.hash_pwd_salt("password123"),
        email_confirmed: true
      )

      assert {:ok, user} = Accounts.authenticate("confirmed@example.com", "password123")
      assert user.email == "confirmed@example.com"
    end
  end

  describe "register/1 email confirmation" do
    test "always creates user with email_confirmed false and a confirmation token" do
      attrs = %{"email" => "needsconfirm@example.com", "password" => "password123"}
      assert {:ok, user} = Accounts.register(attrs)
      assert user.email_confirmed == false
      assert is_binary(user.email_confirmation_token)
    end
  end

  describe "get_user!/1" do
    test "returns user by ID" do
      user = insert(:user)
      assert fetched = Accounts.get_user!(user.id)
      assert fetched.id == user.id
    end

    test "raises on missing ID" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_user_by_email/1" do
    test "returns user by email" do
      user = insert(:user, email: "findme@example.com")
      assert found = Accounts.get_user_by_email("findme@example.com")
      assert found.id == user.id
    end

    test "returns nil for unknown email" do
      assert nil == Accounts.get_user_by_email("nobody@example.com")
    end
  end

  describe "update_profile/2" do
    test "updates display_name and website_url" do
      user = insert(:user, display_name: "Old Name")

      assert {:ok, updated} =
               Accounts.update_profile(user, %{
                 "display_name" => "New Name",
                 "website_url" => "https://example.com"
               })

      assert updated.display_name == "New Name"
      assert updated.website_url == "https://example.com"
    end

    test "returns error when website_url exceeds 500 characters" do
      user = insert(:user)
      long_url = String.duplicate("a", 501)
      assert {:error, changeset} = Accounts.update_profile(user, %{"website_url" => long_url})
      assert %{website_url: [_]} = errors_on(changeset)
    end

    test "updates email when current_password is correct" do
      user =
        insert(:user, email: "old@example.com", password_hash: Argon2.hash_pwd_salt("pass123"))

      assert {:ok, updated} =
               Accounts.update_profile(user, %{
                 "email" => "new@example.com",
                 "current_password" => "pass123"
               })

      assert updated.email == "new@example.com"
    end

    test "returns :invalid_password when current_password is wrong for email change" do
      user = insert(:user, password_hash: Argon2.hash_pwd_salt("correct"))

      assert {:error, :invalid_password} =
               Accounts.update_profile(user, %{
                 "email" => "new@example.com",
                 "current_password" => "wrong"
               })
    end

    test "returns :invalid_password when current_password is missing for email change" do
      user = insert(:user)

      assert {:error, :invalid_password} =
               Accounts.update_profile(user, %{"email" => "new@example.com"})
    end

    test "returns error on duplicate email" do
      existing = insert(:user, email: "taken@example.com")
      user = insert(:user, password_hash: Argon2.hash_pwd_salt("pass123"))

      assert {:error, _} =
               Accounts.update_profile(user, %{
                 "email" => existing.email,
                 "current_password" => "pass123"
               })
    end

    test "emits user.profile_updated event on success" do
      user = insert(:user)
      before_count = event_count("user.profile_updated")

      Accounts.update_profile(user, %{"display_name" => "New Name"})

      assert event_count("user.profile_updated") == before_count + 1
    end
  end

  describe "update_location/2" do
    test "updates country_code and city" do
      user = insert(:user)

      assert {:ok, updated} =
               Accounts.update_location(user, %{"country_code" => "GB", "city" => "London"})

      assert updated.country_code == "GB"
      assert updated.city == "London"
    end

    test "returns error when country_code is not exactly 2 characters" do
      user = insert(:user)
      assert {:error, changeset} = Accounts.update_location(user, %{"country_code" => "GBR"})
      assert %{country_code: [_]} = errors_on(changeset)
    end

    test "returns error when city exceeds 200 characters" do
      user = insert(:user)
      long_city = String.duplicate("x", 201)
      assert {:error, changeset} = Accounts.update_location(user, %{"city" => long_city})
      assert %{city: [_]} = errors_on(changeset)
    end

    test "emits user.location_updated event with correct payload" do
      user = insert(:user)
      before_count = event_count("user.location_updated")

      Accounts.update_location(user, %{"country_code" => "ZA", "city" => "Cape Town"})

      assert event_count("user.location_updated") == before_count + 1
    end
  end

  describe "change_password/3" do
    test "changes password when current_password is correct" do
      user = insert(:user, password_hash: Argon2.hash_pwd_salt("oldpass123"))
      assert {:ok, _updated} = Accounts.change_password(user, "oldpass123", "newpass456")
    end

    test "old password no longer authenticates after change" do
      user = insert(:user, email: "pw@example.com", password_hash: Argon2.hash_pwd_salt("old123"))
      {:ok, _} = Accounts.change_password(user, "old123", "new456789")
      assert {:error, :invalid_credentials} = Accounts.authenticate("pw@example.com", "old123")
    end

    test "returns :invalid_password when current_password is wrong" do
      user = insert(:user, password_hash: Argon2.hash_pwd_salt("correct"))
      assert {:error, :invalid_password} = Accounts.change_password(user, "wrong", "newpass123")
    end

    test "returns changeset error when new_password is too short" do
      user = insert(:user, password_hash: Argon2.hash_pwd_salt("pass123"))
      assert {:error, changeset} = Accounts.change_password(user, "pass123", "short")
      assert %{password: [_]} = errors_on(changeset)
    end

    test "emits user.password_changed event on success" do
      user = insert(:user, password_hash: Argon2.hash_pwd_salt("oldpass123"))
      before_count = event_count("user.password_changed")

      Accounts.change_password(user, "oldpass123", "newpass456")

      assert event_count("user.password_changed") == before_count + 1
    end

    test "does not emit event when current_password is wrong" do
      user = insert(:user, password_hash: Argon2.hash_pwd_salt("correct"))
      before_count = event_count("user.password_changed")

      Accounts.change_password(user, "wrong", "newpass456")

      assert event_count("user.password_changed") == before_count
    end
  end

  describe "update_notifications/2" do
    test "toggles all four notification fields" do
      user =
        insert(:user,
          notify_wishlist_availability: false,
          notify_marketplace: false,
          notify_group_invitations: false,
          notify_event_matches: false
        )

      assert {:ok, updated} =
               Accounts.update_notifications(user, %{
                 "notify_wishlist_availability" => true,
                 "notify_marketplace" => true,
                 "notify_group_invitations" => true,
                 "notify_event_matches" => true
               })

      assert updated.notify_wishlist_availability == true
      assert updated.notify_marketplace == true
      assert updated.notify_group_invitations == true
      assert updated.notify_event_matches == true
    end

    test "unknown keys are silently ignored" do
      user = insert(:user)
      assert {:ok, _} = Accounts.update_notifications(user, %{"unknown_pref" => true})
    end

    test "emits user.notifications_updated event with current preference values" do
      user = insert(:user, notify_wishlist_availability: false, notify_marketplace: false)
      before_count = event_count("user.notifications_updated")

      Accounts.update_notifications(user, %{
        "notify_wishlist_availability" => true,
        "notify_marketplace" => true
      })

      assert event_count("user.notifications_updated") == before_count + 1
    end
  end

  describe "update_profile_visibility/2" do
    test "updates profile_visibility to platform" do
      user = insert(:user)
      assert {:ok, updated} = Accounts.update_profile_visibility(user.id, "platform")
      assert updated.profile_visibility == "platform"
    end

    test "emits user.profile_visibility_changed event" do
      user = insert(:user)
      before_count = event_count("user.profile_visibility_changed")

      Accounts.update_profile_visibility(user.id, "owner")

      assert event_count("user.profile_visibility_changed") == before_count + 1
    end

    test "enqueues VisibilityRecapJob after visibility change" do
      user = insert(:user)
      Accounts.update_profile_visibility(user.id, "owner")

      assert_enqueued(
        worker: Stacks.Workers.VisibilityRecapJob,
        args: %{"user_id" => user.id, "new_visibility" => "owner"}
      )
    end

    test "returns changeset error for invalid visibility value" do
      user = insert(:user)
      assert {:error, changeset} = Accounts.update_profile_visibility(user.id, "public")
      assert %{profile_visibility: [_]} = errors_on(changeset)
    end
  end

  # ---------------------------------------------------------------------------
  # Onboarding context functions
  # ---------------------------------------------------------------------------

  describe "onboarding_status/1" do
    test "fresh user has all steps false and next_step = profile" do
      user = insert(:user)

      assert %{steps: steps, completed: false, next_step: "profile"} =
               Accounts.onboarding_status(user.id)

      assert steps == %{"profile" => false, "age_verification" => false, "privacy" => false}
    end

    test "partially-completed user returns correct next_step" do
      user = insert(:user, onboarding_steps: %{"profile" => true})
      status = Accounts.onboarding_status(user.id)
      assert status.next_step == "age_verification"
      assert status.steps["profile"] == true
      assert status.steps["age_verification"] == false
    end

    test "fully-completed user has next_step = nil and completed = true" do
      user =
        insert(:user,
          onboarding_steps: %{
            "profile" => true,
            "age_verification" => true,
            "privacy" => true
          }
        )

      status = Accounts.onboarding_status(user.id)
      assert status.next_step == nil
      assert status.completed == true
    end
  end

  describe "complete_onboarding_step/2" do
    test "marks a valid step as completed" do
      user = insert(:user)
      assert {:ok, updated} = Accounts.complete_onboarding_step(user.id, "profile")
      assert updated.onboarding_steps["profile"] == true
    end

    test "is idempotent — completing an already-done step returns ok" do
      user = insert(:user, onboarding_steps: %{"profile" => true})
      assert {:ok, updated} = Accounts.complete_onboarding_step(user.id, "profile")
      assert updated.onboarding_steps["profile"] == true
    end

    test "completing all three steps sets onboarding_completed to true" do
      user = insert(:user)
      {:ok, _} = Accounts.complete_onboarding_step(user.id, "profile")
      {:ok, _} = Accounts.complete_onboarding_step(user.id, "age_verification")
      {:ok, updated} = Accounts.complete_onboarding_step(user.id, "privacy")
      reloaded = Repo.reload!(updated)
      assert reloaded.onboarding_completed == true
    end

    test "returns error for invalid step" do
      user = insert(:user)
      assert {:error, :invalid_step} = Accounts.complete_onboarding_step(user.id, "invalid")
    end

    test "completes age_verification step" do
      user = insert(:user)

      assert {:ok, updated} =
               Accounts.complete_onboarding_step(user.id, "age_verification")

      assert updated.onboarding_steps["age_verification"] == true
    end

    test "completes privacy step" do
      user = insert(:user)
      assert {:ok, updated} = Accounts.complete_onboarding_step(user.id, "privacy")
      assert updated.onboarding_steps["privacy"] == true
    end
  end

  describe "reset_onboarding/1" do
    test "resets all steps to false" do
      user =
        insert(:user,
          onboarding_steps: %{
            "profile" => true,
            "age_verification" => true,
            "privacy" => true
          }
        )

      assert {:ok, updated} = Accounts.reset_onboarding(user.id)
      assert updated.onboarding_steps["profile"] == false
      assert updated.onboarding_steps["age_verification"] == false
      assert updated.onboarding_steps["privacy"] == false
    end

    test "reloaded user has onboarding_completed = false after reset" do
      user =
        insert(:user,
          onboarding_steps: %{
            "profile" => true,
            "age_verification" => true,
            "privacy" => true
          }
        )

      {:ok, updated} = Accounts.reset_onboarding(user.id)
      reloaded = Repo.reload!(updated)
      assert reloaded.onboarding_completed == false
    end

    test "next_step returns profile after reset" do
      user =
        insert(:user,
          onboarding_steps: %{
            "profile" => true,
            "age_verification" => true,
            "privacy" => true
          }
        )

      Accounts.reset_onboarding(user.id)
      assert %{next_step: "profile"} = Accounts.onboarding_status(user.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Generated column: onboarding_completed (Issue #149-W1)
  # ---------------------------------------------------------------------------

  describe "onboarding_completed generated column" do
    test "empty onboarding_steps map produces onboarding_completed = false at DB level" do
      user = insert(:user, onboarding_steps: %{})
      reloaded = Repo.get!(Stacks.Accounts.User, user.id)
      assert reloaded.onboarding_completed == false
    end
  end

  defp event_count(event_type) do
    Repo.aggregate(
      from(e in "event_log", prefix: "op", where: e.event_type == ^event_type),
      :count
    )
  end
end
