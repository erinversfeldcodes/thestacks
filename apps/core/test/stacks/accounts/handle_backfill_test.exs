defmodule Stacks.Accounts.HandleBackfillTest do
  @moduledoc """
    Coverage for the DEPLOY-TIME handle guarantees introduced in and shipped in
    this branch (decision: roll forward with the single-release NOT NULL tighten):

    1. The raw backfill SQL in `20260714200500_backfill_and_constrain_user_handles.exs`
       that populates existing NULL handles on deploy — never exercised by the app-layer
       tests (a fresh DB has no null-handle rows), yet it runs against REAL user data.
    2. The DB-level `NOT NULL` + case-insensitive UNIQUE constraints actually enforce
       (beyond the changeset-level `unique_constraint`/`validate_required`).
  """
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Core.Repo

  @backfill_expr """
  coalesce(
    nullif(
      substr(
        trim(both '_' from regexp_replace(
          lower(coalesce(nullif(trim(display_name), ''), 'reader')),
          '[^a-z0-9]+', '_', 'g'
        )),
        1, 20
      ),
      ''
    ),
    'reader'
  ) || '_' || substr(md5(random()::text || id::text), 1, 6)
  """

  defp backfill(display_name) do
    {:ok, %{rows: [[handle]]}} =
      Repo.query(
        "SELECT #{@backfill_expr} FROM (VALUES ($1::text, gen_random_uuid())) AS t(display_name, id)",
        [display_name]
      )

    handle
  end

  describe "backfill SQL" do
    test "produces a valid handle (matches the app's handle format) for a normal name" do
      handle = backfill("Ada Lovelace")
      assert handle =~ ~r/^ada_lovelace_[0-9a-f]{6}$/
      assert handle =~ ~r/^[a-z0-9_]{3,30}$/
    end

    test "collapses punctuation/whitespace to underscores and lowercases" do
      assert backfill("Ada  Lovelace!!") =~ ~r/^ada_lovelace_[0-9a-f]{6}$/
    end

    test "falls back to 'reader' for a blank, whitespace, or non-alphanumeric name" do
      assert backfill("") =~ ~r/^reader_[0-9a-f]{6}$/
      assert backfill("   ") =~ ~r/^reader_[0-9a-f]{6}$/
      assert backfill("💥") =~ ~r/^reader_[0-9a-f]{6}$/
      assert backfill("!!!") =~ ~r/^reader_[0-9a-f]{6}$/
    end

    test "truncates the slug to 20 chars before the suffix (stays within the 30-char limit)" do
      handle = backfill("Supercalifragilisticexpialidocious Reader")
      assert handle =~ ~r/^[a-z0-9_]{3,30}$/
      slug = String.replace(handle, ~r/_[0-9a-f]{6}$/, "")
      assert String.length(slug) <= 20
    end

    test "the random suffix makes two identical display names collide-resistant" do
      handles = for _ <- 1..50, do: backfill("Ada Lovelace")
      assert length(Enum.uniq(handles)) == length(handles)
    end
  end

  describe "DB-level constraints" do
    test "the NOT NULL constraint rejects a handle-less insert" do
      assert_raise Postgrex.Error, ~r/handle.*not.?null|null.*handle/is, fn ->
        Repo.query!(
          "INSERT INTO op.users (id, email, password_hash, display_name, role, profile_visibility, created_at, updated_at) " <>
            "VALUES (gen_random_uuid(), 'nohandle@example.test', 'x', 'No Handle', 'user', 'owner', now(), now())"
        )
      end
    end

    test "the lower(handle) unique index rejects a case-insensitive duplicate" do
      insert(:user, handle: "duplicate_me")

      assert_raise Postgrex.Error, ~r/unique|duplicate key/i, fn ->
        Repo.query!(
          "INSERT INTO op.users (id, email, password_hash, display_name, handle, role, profile_visibility, created_at, updated_at) " <>
            "VALUES (gen_random_uuid(), 'dupe@example.test', 'x', 'Dupe', 'DUPLICATE_ME', 'user', 'owner', now(), now())"
        )
      end
    end
  end
end
