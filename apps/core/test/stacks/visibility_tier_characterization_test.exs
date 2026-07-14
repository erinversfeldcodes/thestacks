defmodule Stacks.VisibilityTierCharacterizationTest do
  @moduledoc """
  GOLDEN-MASTER characterization of how a Book's `visibility_tier` resolves
  through `Stacks.Visibility.resolve_visibility/2` **today**, BEFORE the #209
  decomposition of `visibility_tier` into the orthogonal (Audience,
  Discoverability, AgeGate) axes (ADR-018).

  Every row below pins the CURRENT composite `:visible | :hidden` decision. The
  decomposition (Phase 2/5) must reproduce this table EXACTLY — a green table is
  the exit criterion. Any change to a row is a deliberate, reviewed behaviour
  change, never a silent side effect of the refactor.

  ## The finding this table freezes (corrected by the test itself)

  The DB column is a Postgres ENUM: `CREATE TYPE op.visibility_tier AS ENUM
  ('public', 'age_gated')` (`20260305000004_create_books.exs`). The proto
  `VisibilityTier` enum ALSO declares `unlisted` and `private`, but those were
  never added to the DB type — they are **impossible to store** (an insert of
  `"private"` raises `invalid input value for enum visibility_tier`). So for the
  #209 decomposition there are only TWO live values to account for, and ZERO rows
  of `unlisted`/`private` to migrate.

  At resolution time the resolver coerces every book to `"public"` at the
  resource-visibility level (`get_resource_visibility/1`) and honours ONLY
  `age_gated` (via `check_age_gate/2`); books have no `user_id`, so no owner match
  or profile ceiling applies. The decomposition is therefore simply: extract the
  `age_gated` boolean into an AgeGate axis; `public` == not-age-gated. The proto's
  `unlisted`/`private` (Discoverability / owner-only) are aspirational — any future
  use is a NEW feature, not a migration of existing data, and would add rows here.
  """
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Visibility

  # {visibility_tier, viewer_kind, expected}. Only the two ENUM-storable tiers.
  # viewer_kind: :unauthenticated | :verified (authed, age_verified) | :unverified
  @truth_table [
    # public — visible to everyone
    {"public", :unauthenticated, :visible},
    {"public", :verified, :visible},
    {"public", :unverified, :visible},
    # age_gated — the ONLY enforced tier: verified-authed only
    {"age_gated", :unauthenticated, :hidden},
    {"age_gated", :verified, :visible},
    {"age_gated", :unverified, :hidden}
  ]

  for {tier, viewer_kind, expected} <- @truth_table do
    test "visibility_tier=#{tier} + #{viewer_kind} viewer -> #{expected}" do
      book = insert(:book, visibility_tier: unquote(tier))
      viewer = build_viewer(unquote(viewer_kind))

      assert Visibility.resolve_visibility(book, viewer) == unquote(expected)
    end
  end

  defp build_viewer(:unauthenticated), do: :unauthenticated
  defp build_viewer(:verified), do: {:platform_user, insert(:user, age_verified: true).id}
  defp build_viewer(:unverified), do: {:platform_user, insert(:user, age_verified: false).id}
end
