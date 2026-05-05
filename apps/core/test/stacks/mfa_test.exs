defmodule Stacks.MFATest do
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.MFA
  alias Stacks.MFA.UserMFA

  describe "begin_enrollment/1" do
    test "returns secret, provisioning_uri, and 10 recovery codes" do
      user = insert(:user)
      {:ok, result} = MFA.begin_enrollment(user)

      assert is_binary(result.secret)
      assert is_binary(result.provisioning_uri)
      assert is_list(result.recovery_codes)
      assert length(result.recovery_codes) == 10
    end

    test "provisioning_uri contains the user's email" do
      user = insert(:user, email: "totp_test@example.com")
      {:ok, result} = MFA.begin_enrollment(user)

      assert String.contains?(result.provisioning_uri, URI.encode("totp_test@example.com"))
    end

    test "recovery_codes are 12-character uppercase hex strings" do
      user = insert(:user)
      {:ok, result} = MFA.begin_enrollment(user)

      for code <- result.recovery_codes do
        assert String.length(code) == 12
        assert code == String.upcase(code)
        assert code =~ ~r/^[0-9A-F]+$/
      end
    end

    test "each call generates a different secret" do
      user = insert(:user)
      {:ok, result1} = MFA.begin_enrollment(user)
      {:ok, result2} = MFA.begin_enrollment(user)

      refute result1.secret == result2.secret
    end
  end

  describe "confirm_enrollment/4" do
    test "persists UserMFA when TOTP code is valid" do
      user = insert(:user)
      {:ok, %{secret: secret, recovery_codes: codes}} = MFA.begin_enrollment(user)
      valid_code = NimbleTOTP.verification_code(secret)

      assert {:ok, %UserMFA{} = mfa} = MFA.confirm_enrollment(user, valid_code, secret, codes)
      assert mfa.user_id == user.id
      assert mfa.enabled_at != nil
    end

    test "returns {:error, :invalid_code} for wrong code" do
      user = insert(:user)
      {:ok, %{secret: secret, recovery_codes: codes}} = MFA.begin_enrollment(user)

      assert {:error, :invalid_code} = MFA.confirm_enrollment(user, "000000", secret, codes)
    end

    test "re-enrollment replaces old record (idempotent on conflict)" do
      user = insert(:user)
      {:ok, %{secret: secret1, recovery_codes: codes1}} = MFA.begin_enrollment(user)
      valid_code1 = NimbleTOTP.verification_code(secret1)
      {:ok, _} = MFA.confirm_enrollment(user, valid_code1, secret1, codes1)

      {:ok, %{secret: secret2, recovery_codes: codes2}} = MFA.begin_enrollment(user)
      valid_code2 = NimbleTOTP.verification_code(secret2)
      {:ok, mfa2} = MFA.confirm_enrollment(user, valid_code2, secret2, codes2)

      assert mfa2.user_id == user.id
      count = Core.Repo.aggregate(UserMFA, :count, :id)
      assert count == 1
    end
  end

  describe "verify_totp/2" do
    test "returns :ok for valid TOTP code when enrolled" do
      user = insert(:user)
      {:ok, %{secret: secret, recovery_codes: codes}} = MFA.begin_enrollment(user)
      valid_code = NimbleTOTP.verification_code(secret)
      {:ok, _} = MFA.confirm_enrollment(user, valid_code, secret, codes)

      new_code = NimbleTOTP.verification_code(secret)
      assert :ok = MFA.verify_totp(user, new_code)
    end

    test "returns {:error, :invalid_code} for wrong code" do
      user = insert(:user)
      {:ok, %{secret: secret, recovery_codes: codes}} = MFA.begin_enrollment(user)
      valid_code = NimbleTOTP.verification_code(secret)
      {:ok, _} = MFA.confirm_enrollment(user, valid_code, secret, codes)

      assert {:error, :invalid_code} = MFA.verify_totp(user, "000000")
    end

    test "returns {:error, :not_enrolled} when no UserMFA record" do
      user = insert(:user)

      assert {:error, :not_enrolled} = MFA.verify_totp(user, "123456")
    end
  end

  describe "verify_recovery_code/2" do
    setup do
      user = insert(:user)
      {:ok, %{secret: secret, recovery_codes: codes}} = MFA.begin_enrollment(user)
      valid_code = NimbleTOTP.verification_code(secret)
      {:ok, mfa} = MFA.confirm_enrollment(user, valid_code, secret, codes)
      {:ok, user: user, codes: codes, mfa: mfa}
    end

    test "returns :ok for a valid unused recovery code", %{user: user, codes: codes} do
      code = List.first(codes)
      assert :ok = MFA.verify_recovery_code(user, code)
    end

    test "removes the used code from the stored list", %{user: user, codes: codes} do
      code = List.first(codes)
      :ok = MFA.verify_recovery_code(user, code)

      assert {:error, :invalid_code} = MFA.verify_recovery_code(user, code)
    end

    test "returns {:error, :invalid_code} for unknown code", %{user: user} do
      assert {:error, :invalid_code} = MFA.verify_recovery_code(user, "ZZZZZZZZZZZZ")
    end

    test "returns {:error, :invalid_code} for already-used code (removed from list)",
         %{user: user, codes: codes} do
      code = List.first(codes)
      :ok = MFA.verify_recovery_code(user, code)

      assert {:error, :invalid_code} = MFA.verify_recovery_code(user, code)
    end
  end

  describe "mfa_enabled?/1" do
    test "returns true when UserMFA record exists" do
      user = insert(:user)
      {:ok, %{secret: secret, recovery_codes: codes}} = MFA.begin_enrollment(user)
      valid_code = NimbleTOTP.verification_code(secret)
      {:ok, _} = MFA.confirm_enrollment(user, valid_code, secret, codes)

      assert MFA.mfa_enabled?(user) == true
    end

    test "returns false when no record" do
      user = insert(:user)
      assert MFA.mfa_enabled?(user) == false
    end
  end

  describe "disable/2" do
    setup do
      user = insert(:user)
      {:ok, %{secret: secret, recovery_codes: codes}} = MFA.begin_enrollment(user)
      valid_code = NimbleTOTP.verification_code(secret)
      {:ok, _} = MFA.confirm_enrollment(user, valid_code, secret, codes)
      {:ok, user: user, secret: secret}
    end

    test "deletes UserMFA record when code is valid", %{user: user, secret: secret} do
      code = NimbleTOTP.verification_code(secret)
      assert :ok = MFA.disable(user, code)
      assert MFA.mfa_enabled?(user) == false
    end

    test "returns {:error, :invalid_code} when code is wrong", %{user: user} do
      assert {:error, :invalid_code} = MFA.disable(user, "000000")
    end
  end
end
