defmodule Stacks.Admin.SessionContextTest do
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Admin.SessionContext

  @raw_ip "127.0.0.1"

  defp current_boot_id, do: Core.Application.boot_id()

  describe "create/3" do
    test "creates session with correct fields" do
      user = insert(:owner_user)
      boot_id = current_boot_id()

      {:ok, session} = SessionContext.create(user, @raw_ip, boot_id)

      assert session.user_id == user.id
      assert session.boot_id == boot_id
      assert session.mfa_verified_at == nil
      assert session.revoked_at == nil
    end

    test "stores a KEYED digest of the IP, not a bare hash of it" do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())

      # Deterministic, so session pinning can still compare.
      assert session.ip_hash == Stacks.IPDigest.hash(@raw_ip)

      # But not the unkeyed digest this used to store. That value was invertible
      # by exhausting the IPv4 space, so pinning came at the cost of holding a
      # recoverable network identifier.
      bare = :crypto.hash(:sha256, @raw_ip) |> Base.encode16(case: :lower)
      refute session.ip_hash == bare
    end

    test "sets expires_at to 30 minutes from now" do
      user = insert(:owner_user)
      before = DateTime.utc_now()
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())
      after_dt = DateTime.utc_now()

      expected_min = DateTime.add(before, 29, :minute)
      expected_max = DateTime.add(after_dt, 31, :minute)

      assert DateTime.compare(session.expires_at, expected_min) == :gt
      assert DateTime.compare(session.expires_at, expected_max) == :lt
    end

    test "mfa_verified_at is nil initially" do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())

      assert session.mfa_verified_at == nil
    end
  end

  describe "mark_mfa_verified/1" do
    test "sets mfa_verified_at" do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())

      {:ok, updated} = SessionContext.mark_mfa_verified(session)

      assert updated.mfa_verified_at != nil
      assert DateTime.compare(updated.mfa_verified_at, DateTime.utc_now()) == :lt
    end
  end

  describe "get_valid/2" do
    test "returns {:ok, session} for valid session with matching IP and boot_id" do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())

      assert {:ok, loaded} = SessionContext.get_valid(session.id, @raw_ip)
      assert loaded.id == session.id
    end

    test "returns {:error, :not_found} for unknown session_id" do
      assert {:error, :not_found} = SessionContext.get_valid(Ecto.UUID.generate(), @raw_ip)
    end

    test "returns {:error, :revoked} when revoked_at is set" do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())
      {:ok, revoked} = SessionContext.revoke(session)

      assert {:error, :revoked} = SessionContext.get_valid(revoked.id, @raw_ip)
    end

    test "returns {:error, :expired} when expires_at is in the past" do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())

      past = DateTime.add(DateTime.utc_now(), -60, :minute)

      session
      |> Ecto.Changeset.change(expires_at: past)
      |> Core.Repo.update!()

      assert {:error, :expired} = SessionContext.get_valid(session.id, @raw_ip)
    end

    test "returns {:error, :boot_id_mismatch} when boot_id differs from current" do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())

      session
      |> Ecto.Changeset.change(boot_id: Ecto.UUID.generate())
      |> Core.Repo.update!()

      assert {:error, :boot_id_mismatch} = SessionContext.get_valid(session.id, @raw_ip)
    end

    test "returns {:error, :ip_mismatch} when IP does not match" do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())

      assert {:error, :ip_mismatch} = SessionContext.get_valid(session.id, "10.0.0.1")
    end
  end

  describe "revoke/1" do
    test "sets revoked_at" do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())

      {:ok, revoked} = SessionContext.revoke(session)

      assert revoked.revoked_at != nil
    end

    test "get_valid returns {:error, :revoked} after revoke" do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())
      {:ok, _revoked} = SessionContext.revoke(session)

      assert {:error, :revoked} = SessionContext.get_valid(session.id, @raw_ip)
    end
  end
end
