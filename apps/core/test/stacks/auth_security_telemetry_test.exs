defmodule Stacks.AuthSecurityTelemetryTest do
  @moduledoc """
  Firing tests for the 237 auth-security counters: refresh-token reuse
  (`[:stacks, :auth, :refresh, :reuse_detected]` on the family-burn
  branch) and MFA verify outcome (`[:stacks, :auth, :mfa, :verify]` from
  both TOTP and recovery-code paths). The session absolute-cap emit is
  covered in the AuthController's own tests.
  """

  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.MFA

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = "test-auth-security-tel-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "refresh-token reuse telemetry" do
    setup do
      user = insert(:user)
      fid = Ecto.UUID.generate()

      {:ok, _family} =
        Accounts.rotate_token_family(%{
          family_id: fid,
          user_id: user.id,
          current_jti: "jti-current",
          session_started_at: DateTime.utc_now()
        })

      %{user: user, fid: fid, sub: to_string(user.id)}
    end

    test "emits reuse_detected on the family-burn branch (sad)", %{fid: fid, sub: sub} do
      attach_telemetry([[:stacks, :auth, :refresh, :reuse_detected]])

      assert {:error, :token_reuse_detected} =
               Accounts.check_token_family(fid, "jti-superseded", sub)

      assert Repo.get(AuthTokenFamily, fid).revoked_at

      assert_receive {:telemetry_event, [:stacks, :auth, :refresh, :reuse_detected], %{count: 1},
                      %{}}
    end

    test "does NOT emit for the family's current jti (happy)", %{fid: fid, sub: sub} do
      attach_telemetry([[:stacks, :auth, :refresh, :reuse_detected]])

      assert :ok = Accounts.check_token_family(fid, "jti-current", sub)

      refute_receive {:telemetry_event, [:stacks, :auth, :refresh, :reuse_detected], _, _}, 100
    end

    test "does NOT emit when a mismatched-owner token is rejected without burning",
         %{fid: fid} do
      attach_telemetry([[:stacks, :auth, :refresh, :reuse_detected]])

      assert {:error, :session_revoked} =
               Accounts.check_token_family(fid, "jti-current", Ecto.UUID.generate())

      assert is_nil(Repo.get(AuthTokenFamily, fid).revoked_at)

      refute_receive {:telemetry_event, [:stacks, :auth, :refresh, :reuse_detected], _, _}, 100
    end
  end

  describe "MFA verify telemetry" do
    setup do
      user = insert(:user)
      {:ok, %{secret: secret, recovery_codes: codes}} = MFA.begin_enrollment(user)
      valid_code = NimbleTOTP.verification_code(secret)
      {:ok, _} = MFA.confirm_enrollment(user, valid_code, secret, codes)
      %{user: user, secret: secret, codes: codes}
    end

    test "verify_totp emits outcome :success on a valid code (happy)",
         %{user: user, secret: secret} do
      attach_telemetry([[:stacks, :auth, :mfa, :verify]])

      assert :ok = MFA.verify_totp(user, NimbleTOTP.verification_code(secret))

      assert_receive {:telemetry_event, [:stacks, :auth, :mfa, :verify], %{count: 1},
                      %{outcome: :success}}
    end

    test "verify_totp emits outcome :failure on a wrong code (sad)", %{user: user} do
      attach_telemetry([[:stacks, :auth, :mfa, :verify]])

      assert {:error, :invalid_code} = MFA.verify_totp(user, "000000")

      assert_receive {:telemetry_event, [:stacks, :auth, :mfa, :verify], %{count: 1},
                      %{outcome: :failure}}
    end

    test "verify_recovery_code emits outcome :success on a valid code (happy)",
         %{user: user, codes: codes} do
      attach_telemetry([[:stacks, :auth, :mfa, :verify]])

      assert :ok = MFA.verify_recovery_code(user, List.first(codes))

      assert_receive {:telemetry_event, [:stacks, :auth, :mfa, :verify], %{count: 1},
                      %{outcome: :success}}
    end

    test "verify_recovery_code emits outcome :failure on an unknown code (sad)", %{user: user} do
      attach_telemetry([[:stacks, :auth, :mfa, :verify]])

      assert {:error, :invalid_code} = MFA.verify_recovery_code(user, "ZZZZZZZZZZZZ")

      assert_receive {:telemetry_event, [:stacks, :auth, :mfa, :verify], %{count: 1},
                      %{outcome: :failure}}
    end
  end
end
