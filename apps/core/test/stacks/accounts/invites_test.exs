defmodule Stacks.Accounts.InvitesTest do
  @moduledoc """
  US-14.1.3 — the invite gate, from code mechanics to the GDPR settle step.
  The registration tests run with the flag ON via per-test app env (the
  compile-time :test default stays OFF so every existing registration test
  keeps meaning what it meant).
  """

  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.InviteCode
  alias Stacks.Accounts.Invites
  alias Stacks.GDPR.Deletion
  alias Stacks.GDPR.Export

  setup do
    original = Application.get_env(:core, :invite_only_registration, false)
    on_exit(fn -> Application.put_env(:core, :invite_only_registration, original) end)
    :ok
  end

  defp gate_on, do: Application.put_env(:core, :invite_only_registration, true)

  # One owner per platform (unique constraint) — find-or-insert.
  defp owner do
    Repo.get_by(Stacks.Accounts.User, role: "owner") || insert(:user, role: "owner")
  end

  defp issue!(attrs \\ %{}) do
    {:ok, result} = Invites.issue(owner(), attrs)
    result
  end

  defp register(email, code) do
    Accounts.register(%{
      "email" => email,
      "password" => "long-enough-password",
      "display_name" => "Reader",
      "invite_code" => code
    })
  end

  describe "code mechanics" do
    test "the full code round-trips through hash/1 whatever the reader's casing" do
      {code, hash, prefix} = Invites.generate_code()
      assert Invites.hash(String.downcase(code)) == hash
      assert Invites.hash(String.replace(code, "-", " ")) == hash
      assert String.starts_with?(code, prefix)
      refute prefix == code
    end
  end

  describe "check/1" do
    test "valid, expired, revoked, exhausted, unknown each answer distinctly" do
      %{code: code} = issue!()
      assert {:ok, %{email_bound: false}} = Invites.check(code)

      %{code: expired, invite: row} = issue!()
      row |> Ecto.Changeset.change(expires_at: past()) |> Repo.update!()
      assert {:error, :invite_expired} = Invites.check(expired)

      %{code: revoked, invite: row} = issue!()
      row |> Ecto.Changeset.change(revoked_at: past()) |> Repo.update!()
      assert {:error, :invite_revoked} = Invites.check(revoked)

      %{code: used, invite: row} = issue!()
      row |> Ecto.Changeset.change(use_count: 1) |> Repo.update!()
      assert {:error, :invite_exhausted} = Invites.check(used)

      assert {:error, :invite_not_found} = Invites.check("STK-XXXX-XXXX")
    end
  end

  describe "gated registration" do
    test "refuses without a code, with an unknown code, and consumes on success" do
      gate_on()

      assert {:error, :invite_required} = register("a@example.test", nil)
      assert {:error, :invite_invalid} = register("a@example.test", "STK-0000-0000")

      %{code: code, invite: invite} = issue!()
      assert {:ok, user} = register("a@example.test", code)

      reloaded = Repo.get!(InviteCode, invite.id)
      assert reloaded.use_count == 1
      assert reloaded.redeemed_by_id == user.id
      assert reloaded.redeemed_at

      # …and the same code cannot admit a second account.
      assert {:error, :invite_exhausted} = register("b@example.test", code)
    end

    test "an email-bound code admits only its address, case-insensitively" do
      gate_on()
      %{code: code} = issue!(%{"invited_email" => "Mara@Example.Test"})

      assert {:error, :invite_email_mismatch} = register("other@example.test", code)
      assert {:ok, _} = register("mara@example.test", code)
    end

    test "with the flag OFF the gate adds nothing and any code is ignored" do
      assert {:ok, _} = register("open@example.test", nil)
      assert {:ok, _} = register("open2@example.test", "STK-NONSENSE")
    end

    test "two simultaneous redemptions of a single-use code admit exactly one" do
      gate_on()
      %{code: code} = issue!()

      results =
        [1, 2]
        |> Task.async_stream(
          fn n -> register("racer#{n}@example.test", code) end,
          max_concurrency: 2,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :invite_exhausted}, &1)) == 1
    end
  end

  describe "GDPR settle step" do
    test "a reaped abandoned signup restores the key; a user-requested erasure does not" do
      gate_on()
      %{code: code, invite: invite} = issue!()
      {:ok, user} = register("reaped@example.test", code)

      # Reap path (restore_invite: true): the invitee never got in — key back.
      assert {:ok, _} = Deletion.delete_user_data(user.id, restore_invite: true)
      reloaded = Repo.get!(InviteCode, invite.id)
      assert reloaded.use_count == 0
      assert reloaded.redeemed_at == nil
      # Personal fields are scrubbed either way.
      assert reloaded.redeemed_by_id == nil

      # The code is redeemable again.
      assert {:ok, _} = register("second-chance@example.test", code)

      # User-requested path (opt omitted): the spent credential stays spent.
      %{code: code2, invite: invite2} = issue!(%{"note" => "Mara — book club"})
      {:ok, user2} = register("leaver@example.test", code2)
      assert {:ok, _} = Deletion.delete_user_data(user2.id)

      reloaded2 = Repo.get!(InviteCode, invite2.id)
      assert reloaded2.use_count == 1
      assert reloaded2.note == nil
      assert reloaded2.invited_email == nil
      assert reloaded2.redeemed_by_id == nil
      assert {:error, :invite_exhausted} = register("third@example.test", code2)
    end
  end

  describe "export" do
    test "a redeemed invitation appears as prefix-only; the note never does" do
      gate_on()
      %{code: code, invite: invite} = issue!(%{"note" => "private note"})
      {:ok, user} = register("export@example.test", code)

      {:ok, export} = Export.export_user_data(user.id)
      assert [row] = export.invitations
      assert row.code_prefix == invite.code_prefix
      refute Map.has_key?(row, :note)
      refute Map.has_key?(row, :code_hash)
    end
  end

  describe "ExpiredInvitesSweepJob" do
    test "drops only long-expired unredeemed invitations" do
      %{invite: stale} = issue!()
      stale |> Ecto.Changeset.change(expires_at: days_ago(120)) |> Repo.update!()

      %{invite: recent} = issue!()
      recent |> Ecto.Changeset.change(expires_at: days_ago(10)) |> Repo.update!()

      %{invite: redeemed} = issue!()

      redeemed
      |> Ecto.Changeset.change(expires_at: days_ago(120), use_count: 1, redeemed_at: past())
      |> Repo.update!()

      assert :ok = perform_job(Stacks.Workers.ExpiredInvitesSweepJob, %{})

      assert Repo.get(InviteCode, stale.id) == nil
      assert Repo.get(InviteCode, recent.id)
      assert Repo.get(InviteCode, redeemed.id)
    end
  end

  defp past, do: DateTime.add(DateTime.utc_now(), -3600, :second)
  defp days_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 24 * 3600, :second)
end
