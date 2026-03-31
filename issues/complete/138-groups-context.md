# Issue #138: Groups — Core Context

## Summary
Implement the business logic layer for reading groups and social circles. Schemas and changesets already exist (proto-generated). This issue wires in the CRUD operations, member lifecycle, and invitation flow so the feature is functional before the API layer is added.

## User Stories
US-11.1.1 Create a Group, US-11.1.2 Invite Members, US-11.1.3 Leave a Group, US-11.1.4 Manage Group Members

## Goal
`Stacks.Social` exposes a complete set of context functions for group lifecycle. A group can be created, have members invited (by email or username), accept or decline invitations, and have members leave or be removed. All operations are authorisation-checked (only owners may remove members; only invitees may accept/decline).

## Scope Check
- Does this issue touch more than 3 controllers? → No — implementation only, no controllers.
- Does this issue add more than 2 new endpoints? → No — no endpoints in this issue.
- Does this issue exceed ~300 lines of production code? → Borderline. Split invite + member ops into a separate module if needed.
- Does this issue combine unrelated concerns? → No — all group lifecycle.

## Wiring
- [x] This issue is implementation only. Wired by issue #139.

## Technical Requirements

**`Stacks.Social` additions:**

```elixir
create_group(owner_id, attrs)          # → {:ok, Group} | {:error, changeset}
get_group(group_id, viewer_id)         # → Group | nil (visibility-aware)
list_user_groups(user_id)              # → [Group]
update_group(group_id, owner_id, attrs) # → {:ok, Group} | {:error, :unauthorized | changeset}
delete_group(group_id, owner_id)       # → :ok | {:error, :unauthorized}

invite_member(group_id, inviter_id, invitee_identifier)
  # invitee_identifier: email or username
  # → {:ok, GroupInvitation} | {:error, :not_found | :already_member | changeset}

accept_invitation(invitation_id, user_id)  # → {:ok, GroupMember} | {:error, :not_found | :unauthorized}
decline_invitation(invitation_id, user_id) # → :ok | {:error, :not_found | :unauthorized}

leave_group(group_id, user_id)         # → :ok | {:error, :not_found | :is_owner}
remove_member(group_id, owner_id, member_id) # → :ok | {:error, :unauthorized | :not_found}
list_group_members(group_id, viewer_id) # → [GroupMember] | {:error, :unauthorized}
```

**Group types:** `close_friends`, `broadcast`, `subscription` — stored as string, validated in changeset.

**Events emitted:**
- `group.created`, `group.invitation_sent`, `group.member_joined`, `group.member_left`, `group.member_removed`

**Auth rules:**
- Only `owner` role may invite, remove members, update/delete group
- Owners cannot leave their own group (must transfer ownership or delete)
- Invitation lookup by email matches `users.email`; by username matches `users.username`

## Reviewer Context
- `Stacks.Social` already has `block_user/2` and `unblock_user/2` — match their error-tuple conventions.
- Changesets are already defined: `group_changeset/2`, `group_member_changeset/2`, `group_invitation_changeset/2` — do not redefine.
- All events go through `Stacks.Events.emit/1`.
- Group member role field uses string values `"owner"` and `"member"`.

## Definition of Done
- [ ] `create_group/2` creates group with requesting user as owner member
- [ ] `invite_member/3` creates invitation; returns `:already_member` if user is already in group
- [ ] `accept_invitation/2` creates GroupMember row and deletes the invitation
- [ ] `decline_invitation/2` deletes the invitation record
- [ ] `leave_group/2` returns `{:error, :is_owner}` when owner tries to leave
- [ ] `remove_member/3` returns `{:error, :unauthorized}` for non-owners
- [ ] All 5 events emitted on correct operations
- [ ] Tests cover all happy paths and listed error cases
- [ ] `just verify` passes

## Dependencies
None (schemas and changesets already exist from Issue #131).

## Agent Assignment
elixir-agent

## Progress Notes
