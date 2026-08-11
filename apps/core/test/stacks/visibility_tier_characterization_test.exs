defmodule Stacks.VisibilityTierCharacterizationTest do
  @moduledoc """
  GOLDEN-MASTER characterisation of `visibility_tier` resolution through
  `resolve_visibility/2` TODAY, before the 209 decomposition into
  (Audience, Discoverability, AgeGate) (ADR-018). Every row pins the
  current composite :visible/:hidden decision; the decomposition must
  reproduce this table exactly — a changed row is a reviewed behaviour
  change, never a silent side effect.
  """
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Visibility

  @truth_table [
    {"public", :unauthenticated, :visible},
    {"public", :verified, :visible},
    {"public", :unverified, :visible},
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
