defmodule Stacks.SocialTest do
  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Social

  # ---------------------------------------------------------------------------
  # block_user/2
  # ---------------------------------------------------------------------------

  describe "block_user/2" do
    test "valid block → {:ok, block} and block row exists in DB" do
      blocker = insert(:user)
      blocked = insert(:user)

      assert {:ok, block} = Social.block_user(blocker.id, blocked.id)
      assert block.blocker_id == blocker.id
      assert block.blocked_id == blocked.id

      count =
        Repo.one(
          from(b in "user_blocks",
            where: b.blocker_id == ^blocker.id and b.blocked_id == ^blocked.id,
            select: count(b.id)
          ),
          prefix: "op"
        )

      assert count == 1
    end

    test "duplicate block → returns error (unique constraint)" do
      blocker = insert(:user)
      blocked = insert(:user)

      {:ok, _} = Social.block_user(blocker.id, blocked.id)

      assert {:error, _reason} = Social.block_user(blocker.id, blocked.id)
    end

    test "block_user/2 emits social.user_blocked event" do
      blocker = insert(:user)
      blocked = insert(:user)

      {:ok, _block} = Social.block_user(blocker.id, blocked.id)

      event_count =
        Repo.one(
          from(e in "event_log",
            where: e.event_type == "social.user_blocked" and e.aggregate_id == ^blocker.id,
            select: count(e.id)
          ),
          prefix: "op"
        )

      assert event_count >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # unblock_user/2
  # ---------------------------------------------------------------------------

  describe "unblock_user/2" do
    test "existing block → {:ok, :unblocked} and row removed" do
      blocker = insert(:user)
      blocked = insert(:user)

      {:ok, _} = Social.block_user(blocker.id, blocked.id)

      assert {:ok, :unblocked} = Social.unblock_user(blocker.id, blocked.id)

      count =
        Repo.one(
          from(b in "user_blocks",
            where: b.blocker_id == ^blocker.id and b.blocked_id == ^blocked.id,
            select: count(b.id)
          ),
          prefix: "op"
        )

      assert count == 0
    end

    test "non-existent block → {:error, :not_found} or similar" do
      blocker = insert(:user)
      blocked = insert(:user)

      assert {:error, _reason} = Social.unblock_user(blocker.id, blocked.id)
    end

    test "unblock_user/2 emits social.user_unblocked event" do
      blocker = insert(:user)
      blocked = insert(:user)

      {:ok, _} = Social.block_user(blocker.id, blocked.id)
      {:ok, :unblocked} = Social.unblock_user(blocker.id, blocked.id)

      event_count =
        Repo.one(
          from(e in "event_log",
            where: e.event_type == "social.user_unblocked" and e.aggregate_id == ^blocker.id,
            select: count(e.id)
          ),
          prefix: "op"
        )

      assert event_count >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # blocked?/2
  # ---------------------------------------------------------------------------

  describe "blocked?/2" do
    test "A blocks B: blocked?(b_id, a_id) → true (bidirectional)" do
      user_a = insert(:user)
      user_b = insert(:user)

      {:ok, _} = Social.block_user(user_a.id, user_b.id)

      assert true == Social.blocked?(user_b.id, user_a.id)
    end

    test "A blocks B: blocked?(a_id, b_id) → true (bidirectional)" do
      user_a = insert(:user)
      user_b = insert(:user)

      {:ok, _} = Social.block_user(user_a.id, user_b.id)

      assert true == Social.blocked?(user_a.id, user_b.id)
    end

    test "no block: blocked?(a_id, b_id) → false" do
      user_a = insert(:user)
      user_b = insert(:user)

      assert false == Social.blocked?(user_a.id, user_b.id)
    end
  end

  # ---------------------------------------------------------------------------
  # blocked_by?/2
  # ---------------------------------------------------------------------------

  describe "list_blocked_users/2" do
    test "returns {[], 0} when user has no blocks" do
      user = insert(:user)
      assert {[], 0} = Social.list_blocked_users(user.id)
    end

    test "returns blocked users with display_name and blocked_at" do
      blocker = insert(:user)
      blocked = insert(:user)
      {:ok, _} = Social.block_user(blocker.id, blocked.id)

      {results, total} = Social.list_blocked_users(blocker.id)
      assert total == 1
      assert [entry] = results
      assert entry.id == blocked.id
      assert entry.display_name == blocked.display_name
      assert %DateTime{} = entry.blocked_at
    end

    test "does not return users blocked by others" do
      user_a = insert(:user)
      user_b = insert(:user)
      user_c = insert(:user)
      {:ok, _} = Social.block_user(user_b.id, user_c.id)

      {results, total} = Social.list_blocked_users(user_a.id)
      assert total == 0
      assert results == []
    end
  end

  describe "blocked_by?/2" do
    test "A blocks B: blocked_by?(a_id, b_id) → true (A is the blocker)" do
      user_a = insert(:user)
      user_b = insert(:user)

      {:ok, _} = Social.block_user(user_a.id, user_b.id)

      assert true == Social.blocked_by?(user_a.id, user_b.id)
    end

    test "A blocks B: blocked_by?(b_id, a_id) → false (B did not block A)" do
      user_a = insert(:user)
      user_b = insert(:user)

      {:ok, _} = Social.block_user(user_a.id, user_b.id)

      assert false == Social.blocked_by?(user_b.id, user_a.id)
    end
  end

  # ---------------------------------------------------------------------------
  # create_group/2
  # ---------------------------------------------------------------------------

  describe "create_group/2" do
    test "happy path: group created, owner is member, event emitted" do
      owner = insert(:user)

      assert {:ok, group} =
               Social.create_group(owner.id, %{name: "Book Club", type: "close_friends"})

      assert group.name == "Book Club"
      assert group.owner_id == owner.id

      # Owner should be a member
      assert {:ok, members} = Social.list_group_members(group.id, owner.id)
      assert length(members) == 1
      assert hd(members).user_id == owner.id

      # Event emitted
      event_count =
        Repo.one(
          from(e in "event_log",
            where: e.event_type == "group.created" and e.aggregate_id == ^group.id,
            select: count(e.id)
          ),
          prefix: "op"
        )

      assert event_count >= 1
    end

    test "invalid attrs (empty name) returns changeset error" do
      owner = insert(:user)

      assert {:error, %Ecto.Changeset{}} =
               Social.create_group(owner.id, %{name: "", type: "close_friends"})
    end
  end

  # ---------------------------------------------------------------------------
  # get_group/2
  # ---------------------------------------------------------------------------

  describe "get_group/2" do
    test "returns group for member" do
      owner = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "My Group", type: "close_friends"})

      assert %{id: id} = Social.get_group(group.id, owner.id)
      assert id == group.id
    end

    test "returns platform-visible group for non-member" do
      owner = insert(:user)
      viewer = insert(:user)

      {:ok, group} =
        Social.create_group(owner.id, %{
          name: "Public Group",
          type: "close_friends",
          visibility: "platform"
        })

      assert %{id: id} = Social.get_group(group.id, viewer.id)
      assert id == group.id
    end

    test "returns nil for invite-only group when not a member" do
      owner = insert(:user)
      viewer = insert(:user)

      {:ok, group} =
        Social.create_group(owner.id, %{name: "Private Group", type: "close_friends"})

      assert is_nil(Social.get_group(group.id, viewer.id))
    end

    test "returns nil for non-existent group" do
      viewer = insert(:user)
      assert is_nil(Social.get_group(Ecto.UUID.generate(), viewer.id))
    end
  end

  # ---------------------------------------------------------------------------
  # list_user_groups/1
  # ---------------------------------------------------------------------------

  describe "list_user_groups/1" do
    test "returns groups where user is a member" do
      owner = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group A", type: "close_friends"})

      groups = Social.list_user_groups(owner.id)
      assert length(groups) == 1
      assert hd(groups).id == group.id
    end

    test "does not return groups user was invited to but hasn't joined" do
      owner = insert(:user)
      invitee = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group A", type: "close_friends"})

      Social.invite_member(group.id, owner.id, invitee.email)

      groups = Social.list_user_groups(invitee.id)
      assert groups == []
    end
  end

  # ---------------------------------------------------------------------------
  # update_group/3
  # ---------------------------------------------------------------------------

  describe "update_group/3" do
    test "owner can update name" do
      owner = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Old Name", type: "close_friends"})

      assert {:ok, updated} = Social.update_group(group.id, owner.id, %{name: "New Name"})
      assert updated.name == "New Name"
    end

    test "non-owner returns :unauthorized" do
      owner = insert(:user)
      other = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})

      assert {:error, :unauthorized} = Social.update_group(group.id, other.id, %{name: "Hacked"})
    end
  end

  # ---------------------------------------------------------------------------
  # delete_group/2
  # ---------------------------------------------------------------------------

  describe "delete_group/2" do
    test "owner can delete" do
      owner = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Doomed", type: "close_friends"})

      assert {:ok, _} = Social.delete_group(group.id, owner.id)
      assert is_nil(Social.get_group(group.id, owner.id))
    end

    test "non-owner returns :unauthorized" do
      owner = insert(:user)
      other = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})

      assert {:error, :unauthorized} = Social.delete_group(group.id, other.id)
    end
  end

  # ---------------------------------------------------------------------------
  # invite_member/3
  # ---------------------------------------------------------------------------

  describe "invite_member/3" do
    test "happy path: invitation created, event emitted" do
      owner = insert(:user)
      invitee = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})

      assert {:ok, invitation} = Social.invite_member(group.id, owner.id, invitee.email)
      assert invitation.invited_user_id == invitee.id
      assert invitation.status == "pending"

      event_count =
        Repo.one(
          from(e in "event_log",
            where: e.event_type == "group.invitation_sent" and e.aggregate_id == ^group.id,
            select: count(e.id)
          ),
          prefix: "op"
        )

      assert event_count >= 1
    end

    test ":already_member if user is in group" do
      owner = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})

      assert {:error, :already_member} = Social.invite_member(group.id, owner.id, owner.email)
    end

    test ":already_invited if pending invitation exists" do
      owner = insert(:user)
      invitee = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})

      {:ok, _} = Social.invite_member(group.id, owner.id, invitee.email)
      assert {:error, :already_invited} = Social.invite_member(group.id, owner.id, invitee.email)
    end

    test ":user_not_found for bad identifier" do
      owner = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})

      assert {:error, :user_not_found} =
               Social.invite_member(group.id, owner.id, "nobody@example.com")
    end

    test ":unauthorized if inviter is not a member" do
      owner = insert(:user)
      stranger = insert(:user)
      invitee = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})

      assert {:error, :unauthorized} = Social.invite_member(group.id, stranger.id, invitee.email)
    end

    test "lookup works by email" do
      owner = insert(:user)
      invitee = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})

      assert {:ok, invitation} = Social.invite_member(group.id, owner.id, invitee.email)
      assert invitation.invited_user_id == invitee.id
    end

    test "lookup works by display_name" do
      owner = insert(:user)
      invitee = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})

      assert {:ok, invitation} = Social.invite_member(group.id, owner.id, invitee.display_name)
      assert invitation.invited_user_id == invitee.id
    end

    test "email is preferred over display_name when both could match the identifier" do
      owner = insert(:user)
      # email_user has an email that matches the identifier
      email_user = insert(:user, email: "overlap@example.com")
      # name_user has a display_name that also matches the identifier
      name_user = insert(:user, display_name: "overlap@example.com")
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})

      assert {:ok, invitation} = Social.invite_member(group.id, owner.id, "overlap@example.com")
      # Email match (email_user) should win over display_name match (name_user)
      assert invitation.invited_user_id == email_user.id
      refute invitation.invited_user_id == name_user.id
    end
  end

  # ---------------------------------------------------------------------------
  # accept_invitation/2
  # ---------------------------------------------------------------------------

  describe "accept_invitation/2" do
    test "creates GroupMember, updates invitation to accepted, event emitted" do
      owner = insert(:user)
      invitee = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})
      {:ok, invitation} = Social.invite_member(group.id, owner.id, invitee.email)

      assert {:ok, updated} = Social.accept_invitation(invitation.id, invitee.id)
      assert updated.status == "accepted"
      assert updated.responded_at != nil

      # Invitee is now a member
      groups = Social.list_user_groups(invitee.id)
      assert length(groups) == 1

      event_count =
        Repo.one(
          from(e in "event_log",
            where: e.event_type == "group.member_joined" and e.aggregate_id == ^group.id,
            select: count(e.id)
          ),
          prefix: "op"
        )

      assert event_count >= 1
    end

    test ":not_found for non-existent invitation" do
      user = insert(:user)
      assert {:error, :not_found} = Social.accept_invitation(Ecto.UUID.generate(), user.id)
    end

    test ":unauthorized if wrong user" do
      owner = insert(:user)
      invitee = insert(:user)
      wrong_user = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})
      {:ok, invitation} = Social.invite_member(group.id, owner.id, invitee.email)

      assert {:error, :unauthorized} = Social.accept_invitation(invitation.id, wrong_user.id)
    end
  end

  # ---------------------------------------------------------------------------
  # decline_invitation/2
  # ---------------------------------------------------------------------------

  describe "decline_invitation/2" do
    test "updates invitation to declined" do
      owner = insert(:user)
      invitee = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})
      {:ok, invitation} = Social.invite_member(group.id, owner.id, invitee.email)

      assert {:ok, updated} = Social.decline_invitation(invitation.id, invitee.id)
      assert updated.status == "declined"
      assert updated.responded_at != nil
    end

    test ":not_found for non-existent invitation" do
      user = insert(:user)
      assert {:error, :not_found} = Social.decline_invitation(Ecto.UUID.generate(), user.id)
    end

    test ":unauthorized if wrong user" do
      owner = insert(:user)
      invitee = insert(:user)
      wrong_user = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})
      {:ok, invitation} = Social.invite_member(group.id, owner.id, invitee.email)

      assert {:error, :unauthorized} = Social.decline_invitation(invitation.id, wrong_user.id)
    end
  end

  # ---------------------------------------------------------------------------
  # leave_group/2
  # ---------------------------------------------------------------------------

  describe "leave_group/2" do
    test "member can leave, event emitted" do
      owner = insert(:user)
      member = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})
      {:ok, invitation} = Social.invite_member(group.id, owner.id, member.email)
      {:ok, _} = Social.accept_invitation(invitation.id, member.id)

      assert {:ok, :left} = Social.leave_group(group.id, member.id)

      event_count =
        Repo.one(
          from(e in "event_log",
            where: e.event_type == "group.member_left" and e.aggregate_id == ^group.id,
            select: count(e.id)
          ),
          prefix: "op"
        )

      assert event_count >= 1
    end

    test ":is_owner when owner tries to leave" do
      owner = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})

      assert {:error, :is_owner} = Social.leave_group(group.id, owner.id)
    end

    test ":not_member when user is not in group" do
      owner = insert(:user)
      stranger = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})

      assert {:error, :not_member} = Social.leave_group(group.id, stranger.id)
    end
  end

  # ---------------------------------------------------------------------------
  # remove_member/3
  # ---------------------------------------------------------------------------

  describe "remove_member/3" do
    test "owner can remove member, event emitted" do
      owner = insert(:user)
      member = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})
      {:ok, invitation} = Social.invite_member(group.id, owner.id, member.email)
      {:ok, _} = Social.accept_invitation(invitation.id, member.id)

      assert {:ok, :removed} = Social.remove_member(group.id, owner.id, member.id)

      event_count =
        Repo.one(
          from(e in "event_log",
            where: e.event_type == "group.member_removed" and e.aggregate_id == ^group.id,
            select: count(e.id)
          ),
          prefix: "op"
        )

      assert event_count >= 1
    end

    test ":unauthorized for non-owner" do
      owner = insert(:user)
      member = insert(:user)
      target = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})
      {:ok, inv1} = Social.invite_member(group.id, owner.id, member.email)
      {:ok, _} = Social.accept_invitation(inv1.id, member.id)
      {:ok, inv2} = Social.invite_member(group.id, owner.id, target.email)
      {:ok, _} = Social.accept_invitation(inv2.id, target.id)

      assert {:error, :unauthorized} = Social.remove_member(group.id, member.id, target.id)
    end

    test ":not_found for non-member target" do
      owner = insert(:user)
      stranger = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})

      assert {:error, :not_found} = Social.remove_member(group.id, owner.id, stranger.id)
    end
  end

  # ---------------------------------------------------------------------------
  # grant_visibility/3
  # ---------------------------------------------------------------------------

  describe "grant_visibility/3" do
    test "happy path: grant created for group-visibility bookshelf" do
      owner = insert(:user)
      grantee = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "group")

      assert {:ok, grant} = Social.grant_visibility(bookshelf.id, owner.id, grantee.id)
      assert grant.resource_type == "bookshelf"
      assert grant.resource_id == bookshelf.id
      assert grant.granted_to_id == grantee.id
      assert grant.granted_by_id == owner.id
    end

    test ":unauthorized when caller doesn't own bookshelf" do
      owner = insert(:user)
      other = insert(:user)
      grantee = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "group")

      assert {:error, :unauthorized} = Social.grant_visibility(bookshelf.id, other.id, grantee.id)
    end

    test ":not_applicable when bookshelf visibility != group" do
      owner = insert(:user)
      grantee = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "platform")

      assert {:error, :not_applicable} =
               Social.grant_visibility(bookshelf.id, owner.id, grantee.id)
    end

    test ":already_granted on duplicate" do
      owner = insert(:user)
      grantee = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "group")

      {:ok, _} = Social.grant_visibility(bookshelf.id, owner.id, grantee.id)

      assert {:error, :already_granted} =
               Social.grant_visibility(bookshelf.id, owner.id, grantee.id)
    end
  end

  # ---------------------------------------------------------------------------
  # revoke_visibility/3
  # ---------------------------------------------------------------------------

  describe "revoke_visibility/3" do
    test "happy path: grant deleted" do
      owner = insert(:user)
      grantee = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "group")
      {:ok, _} = Social.grant_visibility(bookshelf.id, owner.id, grantee.id)

      assert :ok = Social.revoke_visibility(bookshelf.id, owner.id, grantee.id)
      refute Social.has_visibility_grant?(bookshelf.id, grantee.id)
    end

    test ":unauthorized for non-owner" do
      owner = insert(:user)
      other = insert(:user)
      grantee = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "group")
      {:ok, _} = Social.grant_visibility(bookshelf.id, owner.id, grantee.id)

      assert {:error, :unauthorized} =
               Social.revoke_visibility(bookshelf.id, other.id, grantee.id)
    end

    test ":not_found when no grant exists" do
      owner = insert(:user)
      grantee = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "group")

      assert {:error, :not_found} =
               Social.revoke_visibility(bookshelf.id, owner.id, grantee.id)
    end
  end

  # ---------------------------------------------------------------------------
  # list_visibility_grants/2
  # ---------------------------------------------------------------------------

  describe "list_visibility_grants/2" do
    test "returns grants for bookshelf owner" do
      owner = insert(:user)
      grantee = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "group")
      {:ok, _} = Social.grant_visibility(bookshelf.id, owner.id, grantee.id)

      assert {:ok, grants} = Social.list_visibility_grants(bookshelf.id, owner.id)
      assert length(grants) == 1
      assert hd(grants).granted_to_id == grantee.id
    end

    test ":unauthorized for non-owner" do
      owner = insert(:user)
      other = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "group")

      assert {:error, :unauthorized} = Social.list_visibility_grants(bookshelf.id, other.id)
    end
  end

  # ---------------------------------------------------------------------------
  # has_visibility_grant?/2
  # ---------------------------------------------------------------------------

  describe "has_visibility_grant?/2" do
    test "returns true when grant exists" do
      owner = insert(:user)
      grantee = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "group")
      {:ok, _} = Social.grant_visibility(bookshelf.id, owner.id, grantee.id)

      assert Social.has_visibility_grant?(bookshelf.id, grantee.id)
    end

    test "returns false when no grant exists" do
      owner = insert(:user)
      grantee = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "group")

      refute Social.has_visibility_grant?(bookshelf.id, grantee.id)
    end
  end

  # ---------------------------------------------------------------------------
  # list_group_members/2
  # ---------------------------------------------------------------------------

  describe "list_group_members/2" do
    test "returns members for a group member viewer" do
      owner = insert(:user)
      {:ok, group} = Social.create_group(owner.id, %{name: "Group", type: "close_friends"})

      assert {:ok, members} = Social.list_group_members(group.id, owner.id)
      assert length(members) == 1
      assert hd(members).user_id == owner.id
    end

    test "returns members for platform-visible group non-member" do
      owner = insert(:user)
      viewer = insert(:user)

      {:ok, group} =
        Social.create_group(owner.id, %{
          name: "Public Group",
          type: "close_friends",
          visibility: "platform"
        })

      assert {:ok, members} = Social.list_group_members(group.id, viewer.id)
      assert length(members) == 1
    end

    test ":unauthorized for invite-only group non-member" do
      owner = insert(:user)
      viewer = insert(:user)

      {:ok, group} =
        Social.create_group(owner.id, %{name: "Private Group", type: "close_friends"})

      assert {:error, :unauthorized} = Social.list_group_members(group.id, viewer.id)
    end
  end
end
