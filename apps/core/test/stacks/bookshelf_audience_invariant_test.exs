defmodule Stacks.BookshelfAudienceInvariantTest do
  @moduledoc """
      The ladder's one structural promise: **a more open tier is never less
      readable than a narrower one.**

      ⛔ THE DEFECT THIS EXISTS FOR WAS THE INVERSION. `op.bookshelves` carried a
      `platform` policy arm and none for `public`, so setting a bookshelf to
      "Anyone with the link" made it readable by NOBODY — strictly less visible
      than the members-only tier below it. A reader who chose to publish was
      silently unpublished, and no local test could see it because the suite
      connects as a superuser, which bypasses row-level security entirely.

      ⚠️ So every case here runs through `Core.AppRole.as_app_role/2`. Without it
      these assertions pass against a database with no policies at all, which is
      the exact shape of the green run that let the inversion ship.

      ⚖️ The invariant is stated as a SUBSET relation rather than as two separate
      "can X read Y" cases on purpose: the bug was not that one tier was wrong in
      isolation, it was that the ORDER between them inverted. A per-tier
      assertion cannot catch an inversion; a comparison can.
  """
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Core.AppRole
  alias Core.Repo
  alias Ecto.Adapters.SQL
  alias Stacks.Scope

  # Read the ids a viewer can actually see at a given visibility, AS the
  # least-privilege role, so the policies are the thing being measured.
  defp readable_ids(visibility) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT id::text FROM op.bookshelves WHERE visibility = $1::visibility_level",
        [visibility]
      )

    rows |> List.flatten() |> MapSet.new()
  end

  defp seed_one_of_each do
    owner = insert(:user)

    %{
      owner: owner,
      public: insert(:bookshelf, user: owner, name: "library", visibility: "public"),
      platform: insert(:bookshelf, user: owner, name: "antilibrary", visibility: "platform")
    }
  end

  describe "public ⊇ platform — the more open tier is never less readable" do
    test "holds for a signed-in viewer who owns neither shelf" do
      %{public: pub, platform: plat} = seed_one_of_each()
      stranger = insert(:user)

      {public_seen, platform_seen} =
        Scope.with_user(stranger.id, fn ->
          AppRole.as_app_role(fn ->
            {readable_ids("public"), readable_ids("platform")}
          end)
        end)

      assert MapSet.member?(platform_seen, plat.id),
             "a signed-in viewer must see a platform shelf — if this fails the fixture is wrong, " <>
               "not the invariant, and the subset assertion below would pass vacuously"

      assert MapSet.member?(public_seen, pub.id),
             "a signed-in viewer must see a public shelf"

      # ⛔ The invariant itself. Stated as an implication between TIERS, because
      # the defect was an inversion of their order and a per-tier assertion
      # cannot see an inversion.
      refute MapSet.size(platform_seen) > 0 and MapSet.size(public_seen) == 0,
             "INVERTED LADDER: a platform shelf is readable while a public one is not. " <>
               "`public` is the more open tier and must be at least as readable."
    end

    test "an anonymous reader sees public and NOT platform" do
      %{public: pub, platform: plat} = seed_one_of_each()

      {public_seen, platform_seen} =
        Scope.anonymous(fn ->
          AppRole.as_app_role(fn ->
            {readable_ids("public"), readable_ids("platform")}
          end)
        end)

      assert MapSet.member?(public_seen, pub.id),
             "ANONYMOUS CANNOT READ A PUBLIC SHELF. This is the defect the issue was filed for: " <>
               "'Anyone with the link' that nobody can follow."

      refute MapSet.member?(platform_seen, plat.id),
             "a platform shelf is members-only and must not reach an anonymous reader"
    end

    test "the owner sees both, so the policies did not simply close everything" do
      # ⛔ ANTI-VACUITY. Without this, a policy set that refused every read would
      # satisfy both cases above — the anonymous one by `refute`, and the
      # signed-in one by the inversion guard never firing.
      %{owner: owner, public: pub, platform: plat} = seed_one_of_each()

      {public_seen, platform_seen} =
        Scope.with_user(owner.id, fn ->
          AppRole.as_app_role(fn ->
            {readable_ids("public"), readable_ids("platform")}
          end)
        end)

      assert MapSet.member?(public_seen, pub.id)
      assert MapSet.member?(platform_seen, plat.id)
    end
  end
end
