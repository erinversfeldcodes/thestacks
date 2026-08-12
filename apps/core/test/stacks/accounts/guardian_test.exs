defmodule Stacks.Accounts.GuardianTest do
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext

  @raw_ip "127.0.0.1"

  defp setup_admin_session(user) do
    boot_id = Core.Application.boot_id()
    {:ok, session} = SessionContext.create(user, @raw_ip, boot_id)
    {:ok, session} = SessionContext.mark_mfa_verified(session)

    {:ok, token, _claims} =
      Guardian.encode_and_sign(user, %{},
        token_type: "admin",
        session_id: session.id,
        boot_id: boot_id,
        ttl: {30, :minute}
      )

    {token, session}
  end

  describe "admin token" do
    test "encodes and verifies admin token with correct claims" do
      user = insert(:owner_user)
      {token, _session} = setup_admin_session(user)

      assert {:ok, _claims} = Guardian.decode_and_verify(token)
    end

    test "admin token contains typ: admin_session claim" do
      user = insert(:owner_user)
      {token, _session} = setup_admin_session(user)

      {:ok, claims} = Guardian.decode_and_verify(token)
      assert claims["typ"] == "admin_session"
    end

    test "admin token contains sid and bid claims" do
      user = insert(:owner_user)
      {token, session} = setup_admin_session(user)

      {:ok, claims} = Guardian.decode_and_verify(token)
      assert claims["sid"] == session.id
      assert claims["bid"] == Core.Application.boot_id()
    end

    test "verify_claims rejects token with wrong boot_id" do
      user = insert(:owner_user)
      boot_id = Core.Application.boot_id()
      {:ok, session} = SessionContext.create(user, @raw_ip, boot_id)

      {:ok, token, _claims} =
        Guardian.encode_and_sign(user, %{},
          token_type: "admin",
          session_id: session.id,
          boot_id: Ecto.UUID.generate(),
          ttl: {30, :minute}
        )

      assert {:error, :invalid_boot_id} = Guardian.decode_and_verify(token)
    end

    test "verify_claims accepts token with correct boot_id" do
      user = insert(:owner_user)
      {token, _session} = setup_admin_session(user)

      assert {:ok, _claims} = Guardian.decode_and_verify(token)
    end

    test "regular user token does not have typ: admin_session" do
      user = insert(:user)
      {:ok, token, _claims} = Guardian.encode_and_sign(user)

      {:ok, claims} = Guardian.decode_and_verify(token)
      refute claims["typ"] == "admin_session"
    end
  end

  describe "access-token TTL" do
    test "a freshly issued user access token expires ~8 hours out" do
      user = insert(:user)
      {:ok, _token, claims} = Guardian.encode_and_sign(user)

      exp = claims["exp"]
      assert is_integer(exp)
      assert_in_delta exp - System.system_time(:second), 8 * 60 * 60, 120
    end

    test "an admin session token still expires in 30 minutes" do
      user = insert(:owner_user)
      {token, _session} = setup_admin_session(user)

      {:ok, claims} = Guardian.decode_and_verify(token)
      exp = claims["exp"]
      assert is_integer(exp)
      assert_in_delta exp - System.system_time(:second), 30 * 60, 120
    end
  end
end
