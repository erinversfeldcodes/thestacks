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

  describe "current_for_user/2 — the one live session, judged" do
    test "returns the operator's live session with matching IP and boot_id" do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())

      assert {:ok, loaded} = SessionContext.current_for_user(user.id, @raw_ip)
      assert loaded.id == session.id
    end

    test "returns {:error, :not_found} for a user with no admin session" do
      user = insert(:owner_user)

      assert {:error, :not_found} = SessionContext.current_for_user(user.id, @raw_ip)
    end

    test "returns {:error, :not_found} when the operator's only session was revoked" do
      # ⚖️ `:not_found`, not `:revoked` — the honest answer to "what is this
      # operator's live elevation?" when there isn't one. A retired row is not a
      # session that failed validation; it is not their session any more.
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())
      {:ok, _} = SessionContext.revoke(session)

      assert {:error, :not_found} = SessionContext.current_for_user(user.id, @raw_ip)
    end

    test "returns {:error, :expired} when expires_at is in the past" do
      # ⛔ Reachable only because expiry is judged by `check_valid/2` and NOT
      # filtered in the query. When it was in both, a row past its expiry was
      # filtered out and this reported `:not_found` — and a change to the expiry
      # rule silently did not apply here at all.
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())

      session
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :minute))
      |> Core.Repo.update!()

      assert {:error, :expired} = SessionContext.current_for_user(user.id, @raw_ip)
    end

    test "returns {:error, :boot_id_mismatch} when boot_id differs from current" do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())

      session
      |> Ecto.Changeset.change(boot_id: Ecto.UUID.generate())
      |> Core.Repo.update!()

      assert {:error, :boot_id_mismatch} = SessionContext.current_for_user(user.id, @raw_ip)
    end

    test "returns {:error, :ip_mismatch} when IP does not match" do
      user = insert(:owner_user)
      {:ok, _session} = SessionContext.create(user, @raw_ip, current_boot_id())

      assert {:error, :ip_mismatch} = SessionContext.current_for_user(user.id, "10.0.0.1")
    end

    test "one operator's session is never returned for another" do
      owner = insert(:owner_user)
      other = insert(:user)
      {:ok, _} = SessionContext.create(owner, @raw_ip, current_boot_id())

      assert {:error, :not_found} = SessionContext.current_for_user(other.id, @raw_ip)
    end
  end

  describe "one live admin session per operator" do
    test "elevating again retires the previous session" do
      # ⛔ THE POLICY, AND THE REASON IT IS A REVOCATION RATHER THAN AN ORDER BY.
      # An operator who elevated on a borrowed machine and walked away used to
      # leave a live, MFA-verified session in this table for its full 30
      # minutes. Elevating elsewhere only out-sorted it; the row stayed usable.
      user = insert(:owner_user)
      {:ok, first} = SessionContext.create(user, "10.0.0.1", current_boot_id())
      {:ok, _first} = SessionContext.mark_mfa_verified(first)

      {:ok, second} = SessionContext.create(user, "10.0.0.2", current_boot_id())

      retired = Core.Repo.get!(Stacks.AdminSession, first.id, prefix: "op")
      assert retired.revoked_at != nil, "elevating again must revoke the previous session"
      assert Core.Repo.get!(Stacks.AdminSession, second.id, prefix: "op").revoked_at == nil
    end

    test "the operator at the NEW location is elevated, and the old one is not" do
      user = insert(:owner_user)
      {:ok, _first} = SessionContext.create(user, "10.0.0.1", current_boot_id())
      {:ok, second} = SessionContext.create(user, "10.0.0.2", current_boot_id())

      assert {:ok, loaded} = SessionContext.current_for_user(user.id, "10.0.0.2")
      assert loaded.id == second.id

      # ⛔ The first location is refused with :ip_mismatch — and the difference
      # from the shape this replaced is WHY. There, both sessions were live and
      # the caller's OWN valid session was merely unreachable behind an
      # `ORDER BY`. Here the first session is genuinely revoked, and the single
      # live elevation really does belong to somewhere else. Same error atom,
      # true statement instead of an accident.
      assert {:error, :ip_mismatch} = SessionContext.current_for_user(user.id, "10.0.0.1")
    end
  end

  describe "revoke/1" do
    test "sets revoked_at" do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())

      {:ok, revoked} = SessionContext.revoke(session)

      assert revoked.revoked_at != nil
    end

    test "current_for_user reports :revoked after revoke" do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, current_boot_id())
      {:ok, _revoked} = SessionContext.revoke(session)

      assert {:error, :not_found} = SessionContext.current_for_user(user.id, @raw_ip)
    end
  end
end
