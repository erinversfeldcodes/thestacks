defmodule Stacks.Social do
  @moduledoc """
  Context for social features: user blocks, groups, group membership,
  group invitations, and visibility grants.
  """

  alias Stacks.Social.{Group, GroupInvitation, GroupMember, UserBlock, VisibilityGrant}

  _ = UserBlock
  _ = Group
  _ = GroupMember
  _ = GroupInvitation
  _ = VisibilityGrant
end
