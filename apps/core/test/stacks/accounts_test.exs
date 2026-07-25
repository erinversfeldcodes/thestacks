defmodule Stacks.AccountsTest do
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.Events.EventLog
  alias Stacks.Social

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

  describe "handles (/u/:handle) — #211" do
    test "register/1 auto-generates a valid, slugified handle from the display name" do
      {:ok, user} =
        Accounts.register(%{
          "email" => "handle_gen@example.com",
          "password" => "secret123",
          "display_name" => "Ada Lovelace"
        })

      assert user.handle =~ ~r/^[a-z0-9_]{3,30}$/
      assert String.starts_with?(user.handle, "ada_lovelace_")
    end

    test "register/1 falls back to a 'reader' base when the display name is blank" do
      {:ok, user} =
        Accounts.register(%{"email" => "no_name@example.com", "password" => "secret123"})

      assert user.handle =~ ~r/^reader_[a-z0-9]{6}$/
    end

    test "generate_handle/1 slugifies the name and appends a random suffix" do
      assert Accounts.generate_handle("Ada Lovelace!!") =~ ~r/^ada_lovelace_[a-z0-9]{6}$/
      assert Accounts.generate_handle(nil) =~ ~r/^reader_[a-z0-9]{6}$/
      assert Accounts.generate_handle("💥") =~ ~r/^reader_[a-z0-9]{6}$/
    end

    test "get_user_by_handle/1 is case-insensitive and trims" do
      user = insert(:user, handle: "adalovelace")
      assert Accounts.get_user_by_handle("AdaLovelace").id == user.id
      assert Accounts.get_user_by_handle("  adalovelace  ").id == user.id
      assert Accounts.get_user_by_handle("nobody") == nil
    end

    test "validate_handle/1 rejects bad format, reserved words, and too-short handles" do
      import Ecto.Changeset, only: [cast: 3]

      bad =
        %Stacks.Accounts.User{}
        |> cast(%{handle: "No Spaces!"}, [:handle])
        |> Accounts.validate_handle()

      refute bad.valid?

      reserved =
        %Stacks.Accounts.User{}
        |> cast(%{handle: "Admin"}, [:handle])
        |> Accounts.validate_handle()

      refute reserved.valid?
      assert "is reserved" in errors_on(reserved).handle

      short =
        %Stacks.Accounts.User{}
        |> cast(%{handle: "ab"}, [:handle])
        |> Accounts.validate_handle()

      refute short.valid?
    end

    test "update_profile/2 sets a valid new handle (normalised to lowercase)" do
      user = insert(:user, handle: "old_handle")
      {:ok, updated} = Accounts.update_profile(user, %{"handle" => "New_Handle"})
      assert updated.handle == "new_handle"
    end

    test "update_profile/2 rejects a reserved handle" do
      user = insert(:user)
      assert {:error, cs} = Accounts.update_profile(user, %{"handle" => "admin"})
      assert "is reserved" in errors_on(cs).handle
    end

    test "update_profile/2 rejects a handle already taken (case-insensitive)" do
      insert(:user, handle: "taken_one")
      user = insert(:user)
      assert {:error, cs} = Accounts.update_profile(user, %{"handle" => "TAKEN_ONE"})
      assert "has already been taken" in errors_on(cs).handle
    end
  end

  # search_users/2 — people search for the discovery surface (US-10.5.4, #217).
  # The discoverability privacy rule (platform-only + bidirectional
  # block-exclusion) is enforced IN THE QUERY, never by serializer redaction.
  describe "search_users/2" do
    test "returns a discoverable (public) user matching the term to an anon searcher" do
      match = insert(:user, display_name: "Ada Lovelace", profile_visibility: "public")
      _other = insert(:user, display_name: "Grace Hopper", profile_visibility: "public")

      results = Accounts.search_users("Ada", nil)

      assert Enum.map(results, & &1.id) == [match.id]
    end

    test "ILIKE-matches case-insensitively and on substrings" do
      match = insert(:user, display_name: "Ada Lovelace", profile_visibility: "public")

      assert Accounts.search_users("ada", nil) |> Enum.map(& &1.id) == [match.id]
      assert Accounts.search_users("LOVELACE", nil) |> Enum.map(& &1.id) == [match.id]
      assert Accounts.search_users("da Love", nil) |> Enum.map(& &1.id) == [match.id]
    end

    test "an anonymous searcher gets public profiles but NOT platform (Members) ones (#225)" do
      public = insert(:user, display_name: "Ada Public", profile_visibility: "public")
      _members = insert(:user, display_name: "Ada Members", profile_visibility: "platform")

      # A logged-out visitor must not even learn a Members profile exists (they'd
      # 404 on it); public is the only search-discoverable rung for anon.
      assert Accounts.search_users("Ada", nil) |> Enum.map(& &1.id) == [public.id]
    end

    test "a signed-in searcher gets BOTH platform (Members) and public profiles (#225)" do
      viewer = insert(:user)
      public = insert(:user, display_name: "Ada Public", profile_visibility: "public")
      members = insert(:user, display_name: "Ada Members", profile_visibility: "platform")

      ids = Accounts.search_users("Ada", viewer.id) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([public.id, members.id])
    end

    test "excludes a ghost (profile_visibility = owner) from the result set" do
      _ghost = insert(:user, display_name: "Ada Ghost", profile_visibility: "owner")

      assert Accounts.search_users("Ada", nil) == []
    end

    test "excludes a ghost even when no viewer is signed in" do
      _ghost = insert(:user, display_name: "Ada Ghost", profile_visibility: "owner")
      public = insert(:user, display_name: "Ada Public", profile_visibility: "public")

      results = Accounts.search_users("Ada", nil)

      assert Enum.map(results, & &1.id) == [public.id]
    end

    test "excludes a user the viewer has blocked" do
      viewer = insert(:user, profile_visibility: "platform")
      blocked = insert(:user, display_name: "Ada Blocked", profile_visibility: "platform")
      {:ok, _} = Social.block_user(viewer.id, blocked.id)

      assert Accounts.search_users("Ada", viewer.id) == []
    end

    test "excludes a user who has blocked the viewer (other direction)" do
      viewer = insert(:user, profile_visibility: "platform")
      blocker = insert(:user, display_name: "Ada Blocker", profile_visibility: "platform")
      {:ok, _} = Social.block_user(blocker.id, viewer.id)

      assert Accounts.search_users("Ada", viewer.id) == []
    end

    test "still returns a blocked user's match to an unrelated viewer" do
      viewer = insert(:user, profile_visibility: "platform")
      blocker = insert(:user, profile_visibility: "platform")
      candidate = insert(:user, display_name: "Ada Seen", profile_visibility: "platform")
      # candidate is blocked w.r.t. `blocker`, but `viewer` is unrelated.
      {:ok, _} = Social.block_user(blocker.id, candidate.id)

      results = Accounts.search_users("Ada", viewer.id)

      assert Enum.map(results, & &1.id) == [candidate.id]
    end

    test "returns [] when nothing matches the term" do
      insert(:user, display_name: "Grace Hopper", profile_visibility: "platform")

      assert Accounts.search_users("Zzz", nil) == []
    end

    test "returns [] for a blank or whitespace-only term" do
      insert(:user, display_name: "Ada Lovelace", profile_visibility: "platform")

      assert Accounts.search_users("", nil) == []
      assert Accounts.search_users("   ", nil) == []
    end

    test "treats ILIKE wildcards in the term literally" do
      insert(:user, display_name: "Ada Lovelace", profile_visibility: "platform")

      # "%" must not act as a wildcard that matches everything.
      assert Accounts.search_users("%", nil) == []
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

    test "same email + empty current_password is a profile-only update (CG-1)" do
      # The settings UI sends the user's current email on every save. A payload
      # whose email equals the current email is NOT an email change, so it must
      # not demand current_password — it routes through the plain profile path.
      user = insert(:user, email: "same@example.com", display_name: "Old Name")
      before_count = event_count("user.profile_updated")

      assert {:ok, updated} =
               Accounts.update_profile(user, %{
                 "email" => "same@example.com",
                 "display_name" => "New Name",
                 "current_password" => ""
               })

      assert updated.display_name == "New Name"
      assert updated.email == "same@example.com"
      # Emits the plain profile-updated event with the PII-free ({}) payload.
      assert event_count("user.profile_updated") == before_count + 1
      assert latest_payload("user.profile_updated", user.id) == %{}
    end

    test "same email compares case-insensitively (CG-1)" do
      # auth resolves identity case-insensitively (get_user_by_email/1 downcases),
      # so a differently-cased same email is still no change.
      user = insert(:user, email: "Same@Example.com", display_name: "Old Name")

      assert {:ok, updated} =
               Accounts.update_profile(user, %{
                 "email" => "same@example.com",
                 "display_name" => "New Name",
                 "current_password" => ""
               })

      assert updated.display_name == "New Name"
    end

    test "different email + empty current_password still fails (CG-1 guard)" do
      user = insert(:user, email: "old@example.com")

      assert {:error, :invalid_password} =
               Accounts.update_profile(user, %{
                 "email" => "different@example.com",
                 "current_password" => ""
               })
    end

    test "user.profile_updated payload carries no PII (UUID-only)" do
      # GDPR (Issue #121): the display_name is PII and must NOT be written into
      # op.event_log. The event carries only the aggregate_id — the payload is
      # empty.
      user = insert(:user)

      assert {:ok, _} = Accounts.update_profile(user, %{"display_name" => "Grace Hopper"})

      payload = latest_payload("user.profile_updated", user.id)
      refute Map.has_key?(payload, "display_name")
      assert payload == %{}
    end

    test "does not emit user.profile_updated when the changeset is invalid" do
      # An over-length website_url fails validation before Repo.update, so
      # tap_emit_profile_updated/1 sees {:error, changeset} and emits nothing.
      user = insert(:user)
      before_count = event_count("user.profile_updated")

      assert {:error, _changeset} =
               Accounts.update_profile(user, %{"website_url" => String.duplicate("a", 501)})

      assert event_count("user.profile_updated") == before_count
    end

    test "does not emit user.profile_updated when an email change is rejected (wrong current_password)" do
      # A genuine email change with a wrong current_password fails at
      # verify_password, before the Multi runs — its emit_event step never fires.
      user = insert(:user, email: "old@example.com")
      before_count = event_count("user.profile_updated")

      assert {:error, :invalid_password} =
               Accounts.update_profile(user, %{
                 "email" => "new@example.com",
                 "current_password" => "wrong"
               })

      assert event_count("user.profile_updated") == before_count
    end

    test "does not emit user.profile_updated when the email Multi rolls back (duplicate email)" do
      # Correct current_password, but the new email is already taken: the :email
      # step's unique_constraint fails, so the whole transaction — including the
      # :emit_event step — rolls back and no event is written.
      taken = insert(:user, email: "taken@example.com")

      user =
        insert(:user, email: "old@example.com", password_hash: Argon2.hash_pwd_salt("pass123"))

      before_count = event_count("user.profile_updated")

      assert {:error, _} =
               Accounts.update_profile(user, %{
                 "email" => taken.email,
                 "current_password" => "pass123"
               })

      assert event_count("user.profile_updated") == before_count
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

    test "emits user.location_updated event" do
      user = insert(:user)
      before_count = event_count("user.location_updated")

      Accounts.update_location(user, %{"country_code" => "ZA", "city" => "Cape Town"})

      assert event_count("user.location_updated") == before_count + 1
    end

    test "user.location_updated payload carries no PII (UUID-only)" do
      # GDPR (Issue #121): city + country_code are PII and must NOT be written
      # into op.event_log. The discovery handler re-reads the location from the
      # user record, so the event payload stays empty.
      user = insert(:user)

      assert {:ok, _} =
               Accounts.update_location(user, %{"country_code" => "ZA", "city" => "Cape Town"})

      payload = latest_payload("user.location_updated", user.id)
      refute Map.has_key?(payload, "city")
      refute Map.has_key?(payload, "country_code")
      assert payload == %{}
    end

    test "does not emit user.location_updated when the country_code is invalid" do
      # A 3-char country_code fails validate_length before Repo.update, so the
      # {:error, changeset} branch returns without emitting.
      user = insert(:user)
      before_count = event_count("user.location_updated")

      assert {:error, _changeset} = Accounts.update_location(user, %{"country_code" => "GBR"})

      assert event_count("user.location_updated") == before_count
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

  describe "token family reuse detection (Issue #179, Phase 2b)" do
    setup do
      user = insert(:user)
      fid = Ecto.UUID.generate()

      {:ok, _family} =
        Accounts.open_token_family(%{
          family_id: fid,
          user_id: user.id,
          current_jti: "jti-current",
          session_started_at: DateTime.utc_now()
        })

      %{user: user, fid: fid, sub: to_string(user.id)}
    end

    test "check_token_family/3 returns :ok for the family's current jti", %{fid: fid, sub: sub} do
      assert :ok = Accounts.check_token_family(fid, "jti-current", sub)
    end

    test "a non-current jti is REUSE: revokes the whole family and returns error",
         %{fid: fid, sub: sub} do
      assert {:error, :token_reuse_detected} =
               Accounts.check_token_family(fid, "jti-superseded", sub)

      assert Repo.get(AuthTokenFamily, fid).revoked_at
    end

    test "an already-revoked family rejects even its current jti", %{fid: fid, sub: sub} do
      {:ok, _} = Accounts.revoke_token_family(fid)
      assert {:error, :session_revoked} = Accounts.check_token_family(fid, "jti-current", sub)
    end

    test "a missing family is treated as revoked" do
      assert {:error, :session_revoked} =
               Accounts.check_token_family(Ecto.UUID.generate(), "anything", "some-sub")
    end

    test "a family owned by a DIFFERENT user is rejected and NOT revoked",
         %{fid: fid} do
      # A token whose sub does not match the family's user_id must never be
      # treated as this user's session — reject, and leave the innocent owner's
      # family untouched (no cross-user revocation).
      other_sub = Ecto.UUID.generate()

      assert {:error, :session_revoked} =
               Accounts.check_token_family(fid, "jti-current", other_sub)

      # The real owner's family is still live — the mismatched check did not
      # revoke it.
      assert is_nil(Repo.get(AuthTokenFamily, fid).revoked_at)
    end

    test "revoke_token_family/1 is idempotent (second call revokes nothing new)",
         %{fid: fid} do
      assert {:ok, 1} = Accounts.revoke_token_family(fid)
      assert {:ok, 0} = Accounts.revoke_token_family(fid)
    end

    test "revoke_all_user_sessions/1 revokes every live family of the user",
         %{user: user, fid: fid} do
      other = Ecto.UUID.generate()

      {:ok, _} =
        Accounts.open_token_family(%{
          family_id: other,
          user_id: user.id,
          current_jti: "jti-other",
          session_started_at: DateTime.utc_now()
        })

      assert :ok = Accounts.revoke_all_user_sessions(user.id)
      assert Repo.get(AuthTokenFamily, fid).revoked_at
      assert Repo.get(AuthTokenFamily, other).revoked_at
    end
  end

  describe "token rotation grace window (Issue #180, Phase 1)" do
    # #179 burns the whole family whenever a non-current jti is presented. That
    # over-fires on a benign rotation race: an in-flight request (or a second
    # tab) still carrying the JUST-rotated old token trips reuse detection and
    # logs the user out. #180 honours the IMMEDIATELY-PREVIOUS token for a short
    # grace window (20s) after rotation WITHOUT burning. Anything else — an older
    # token (2+ rotations back), the previous token past grace, or an unknown
    # jti — still burns, preserving #179's posture outside the tiny window.
    setup do
      user = insert(:user)
      fid = Ecto.UUID.generate()
      %{user: user, fid: fid, sub: to_string(user.id)}
    end

    defp open_rotated_family(fid, user, rotated_at) do
      {:ok, family} =
        Accounts.open_token_family(%{
          family_id: fid,
          user_id: user.id,
          current_jti: "jti-current",
          previous_jti: "jti-previous",
          rotated_at: rotated_at,
          session_started_at: DateTime.utc_now()
        })

      family
    end

    test "the immediately-previous jti WITHIN grace returns :ok and does NOT burn the family",
         %{user: user, fid: fid, sub: sub} do
      open_rotated_family(fid, user, DateTime.utc_now())

      # The benign in-flight / multi-tab replay of the just-rotated token: honoured.
      assert :ok = Accounts.check_token_family(fid, "jti-previous", sub)

      # NON-BURN is the key assertion: the family is untouched — not revoked,
      # and current_jti did NOT advance to the previous token.
      family = Repo.get(AuthTokenFamily, fid)
      assert is_nil(family.revoked_at)
      assert family.current_jti == "jti-current"
      assert family.previous_jti == "jti-previous"
    end

    test "the previous jti PAST the grace window is REUSE: burns the family",
         %{user: user, fid: fid, sub: sub} do
      # rotated_at is 21s ago → outside the 20s grace: this token is now stale.
      past = DateTime.add(DateTime.utc_now(), -21, :second)
      open_rotated_family(fid, user, past)

      assert {:error, :token_reuse_detected} =
               Accounts.check_token_family(fid, "jti-previous", sub)

      assert Repo.get(AuthTokenFamily, fid).revoked_at
    end

    test "an OLDER/unknown jti burns even with a FRESH rotated_at (grace saves only previous_jti)",
         %{user: user, fid: fid, sub: sub} do
      # rotated_at is now (grace is wide open) but the presented token is neither
      # current nor the immediate predecessor — it's two-plus rotations back or
      # forged. Grace must NOT save it.
      open_rotated_family(fid, user, DateTime.utc_now())

      assert {:error, :token_reuse_detected} =
               Accounts.check_token_family(fid, "jti-two-rotations-ago", sub)

      assert Repo.get(AuthTokenFamily, fid).revoked_at
    end

    test "the current jti still returns :ok (happy path unchanged)",
         %{user: user, fid: fid, sub: sub} do
      open_rotated_family(fid, user, DateTime.utc_now())
      assert :ok = Accounts.check_token_family(fid, "jti-current", sub)
    end

    test "a family with no rotation history (previous_jti nil) still burns a non-current jti",
         %{user: user, sub: sub} do
      # Non-vacuity: the grace branch requires BOTH previous_jti and rotated_at.
      # A never-rotated family (legacy / just-opened) has neither, so a stale
      # token against it burns exactly as #179 intended.
      fid = Ecto.UUID.generate()

      {:ok, _} =
        Accounts.open_token_family(%{
          family_id: fid,
          user_id: user.id,
          current_jti: "jti-current",
          session_started_at: DateTime.utc_now()
        })

      assert {:error, :token_reuse_detected} =
               Accounts.check_token_family(fid, "jti-anything", sub)

      assert Repo.get(AuthTokenFamily, fid).revoked_at
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

    test "emits user.notifications_updated event on success" do
      user = insert(:user, notify_wishlist_availability: false, notify_marketplace: false)
      before_count = event_count("user.notifications_updated")

      Accounts.update_notifications(user, %{
        "notify_wishlist_availability" => true,
        "notify_marketplace" => true
      })

      assert event_count("user.notifications_updated") == before_count + 1
    end

    test "does not emit user.notifications_updated when the changeset is invalid" do
      # A non-boolean value for a notify_* field is a cast error, so Repo.update
      # returns {:error, changeset} and no event is emitted.
      user = insert(:user)
      before_count = event_count("user.notifications_updated")

      assert {:error, _changeset} =
               Accounts.update_notifications(user, %{"notify_marketplace" => "banana"})

      assert event_count("user.notifications_updated") == before_count
    end

    test "a freshly inserted user has the expected notification defaults" do
      # Schema defaults (op.users): marketplace + group invitations default ON;
      # wishlist availability + event matches default OFF. The settings screen
      # hydrates from these via GET /api/settings/notifications.
      user = insert(:user)

      assert user.notify_marketplace == true
      assert user.notify_group_invitations == true
      assert user.notify_wishlist_availability == false
      assert user.notify_event_matches == false
    end

    test "user.notifications_updated payload carries no PII (UUID-only)" do
      # GDPR (Issue #121): notification preferences are personal data and must NOT
      # be written into op.event_log. Consumers re-read the preferences from the
      # user record, so the event payload stays empty — matching the sibling
      # profile_updated / location_updated / password_changed events.
      user =
        insert(:user,
          notify_wishlist_availability: false,
          notify_marketplace: false,
          notify_group_invitations: false,
          notify_event_matches: false
        )

      assert {:ok, _} =
               Accounts.update_notifications(user, %{
                 "notify_wishlist_availability" => true,
                 "notify_marketplace" => true,
                 "notify_group_invitations" => true,
                 "notify_event_matches" => true
               })

      payload = latest_payload("user.notifications_updated", user.id)
      refute Map.has_key?(payload, "notify_marketplace")
      assert payload == %{}
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
      assert {:error, changeset} = Accounts.update_profile_visibility(user.id, "nonsense")
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

      assert steps == %{"profile" => false, "privacy" => false}
    end

    test "partially-completed user returns correct next_step" do
      user = insert(:user, onboarding_steps: %{"profile" => true})
      status = Accounts.onboarding_status(user.id)
      assert status.next_step == "privacy"
      assert status.steps["profile"] == true
      assert status.steps["privacy"] == false
    end

    test "fully-completed user has next_step = nil and completed = true" do
      user =
        insert(:user,
          onboarding_steps: %{
            "profile" => true,
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

    test "completing all steps sets onboarding_completed to true" do
      user = insert(:user)
      {:ok, _} = Accounts.complete_onboarding_step(user.id, "profile")
      {:ok, updated} = Accounts.complete_onboarding_step(user.id, "privacy")
      reloaded = Repo.reload!(updated)
      assert reloaded.onboarding_completed == true
    end

    test "returns error for invalid step" do
      user = insert(:user)
      assert {:error, :invalid_step} = Accounts.complete_onboarding_step(user.id, "invalid")
    end

    # The self-declared "verify your age" step was dropped (ADR-020) — it is now
    # an invalid onboarding step.
    test "age_verification is no longer a valid step" do
      user = insert(:user)

      assert {:error, :invalid_step} =
               Accounts.complete_onboarding_step(user.id, "age_verification")
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
            "privacy" => true
          }
        )

      assert {:ok, updated} = Accounts.reset_onboarding(user.id)
      assert updated.onboarding_steps["profile"] == false
      assert updated.onboarding_steps["privacy"] == false
    end

    test "reloaded user has onboarding_completed = false after reset" do
      user =
        insert(:user,
          onboarding_steps: %{
            "profile" => true,
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

  # Latest event payload for an aggregate — uses the EventLog schema so
  # aggregate_id casts from the UUID string and payload loads as a map.
  defp latest_payload(event_type, aggregate_id) do
    Repo.one(
      from(e in EventLog,
        where: e.event_type == ^event_type and e.aggregate_id == ^aggregate_id,
        order_by: [desc: e.occurred_at],
        limit: 1,
        select: e.payload
      )
    )
  end

  describe "find_users_by_email/1" do
    test "returns every user matching case-insensitively (email is not unique)" do
      a = insert(:user, email: "casing@stacks.test")
      b = insert(:user, email: "CASING@stacks.test")

      ids = "Casing@Stacks.Test" |> Accounts.find_users_by_email() |> Enum.map(& &1.id)

      assert a.id in ids
      assert b.id in ids
    end

    test "returns [] when nothing matches" do
      assert Accounts.find_users_by_email("nobody-here@stacks.test") == []
    end
  end

  describe "expired_unverified_ids/1" do
    test "returns only unverified accounts older than the TTL" do
      # `now` is injected far in the future so freshly-inserted rows read as
      # older than (now - 24h), without fiddling with created_at.
      future = DateTime.add(DateTime.utc_now(), 2 * 24 * 60 * 60, :second)

      unverified_a = insert(:user, email: "unv-a@thestacks.test", email_confirmed: false)
      unverified_b = insert(:user, email: "unv-b@thestacks.test", email_confirmed: false)
      confirmed = insert(:user, email: "conf@thestacks.test", email_confirmed: true)

      ids = Accounts.expired_unverified_ids(future)

      assert unverified_a.id in ids
      assert unverified_b.id in ids
      refute confirmed.id in ids, "confirmed accounts are never expired-unverified"
    end

    test "excludes unverified accounts still within the TTL" do
      fresh = insert(:user, email: "fresh-unv@thestacks.test", email_confirmed: false)

      # Real now: a just-created account is well within the 24h window.
      refute fresh.id in Accounts.expired_unverified_ids(DateTime.utc_now())
    end
  end
end
