defmodule Stacks.Social do
  @moduledoc """
  Context for social features: user blocks, groups, group membership,
  group invitations, and visibility grants.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Core.Repo
  alias Stacks.Accounts.User
  alias Stacks.Events
  alias Stacks.Social.UserBlock

  # ── Changeset functions (moved from schema modules) ──

  @group_required_fields [:owner_id, :name, :type]
  @group_optional_fields [:visibility]
  @group_valid_types ~w(close_friends broadcast subscription)
  @group_valid_visibilities ~w(invite_only platform)

  @doc "Changeset for creating or updating a group."
  def group_changeset(group, attrs) do
    group
    |> cast(attrs, @group_required_fields ++ @group_optional_fields)
    |> validate_required(@group_required_fields)
    |> validate_inclusion(:type, @group_valid_types)
    |> validate_inclusion(:visibility, @group_valid_visibilities)
  end

  @group_member_required_fields [:group_id, :user_id, :role]
  @group_member_optional_fields [:joined_at]
  @group_member_valid_roles ~w(member moderator)

  @doc "Changeset for adding a member to a group."
  def group_member_changeset(member, attrs) do
    member
    |> cast(attrs, @group_member_required_fields ++ @group_member_optional_fields)
    |> validate_required(@group_member_required_fields)
    |> validate_inclusion(:role, @group_member_valid_roles)
    |> unique_constraint([:group_id, :user_id])
  end

  @group_invitation_required_fields [:group_id, :invited_by_id, :invited_user_id, :status]
  @group_invitation_optional_fields [:responded_at]
  @group_invitation_valid_statuses ~w(pending accepted declined)

  @doc "Changeset for creating or updating a group invitation."
  def group_invitation_changeset(invitation, attrs) do
    invitation
    |> cast(attrs, @group_invitation_required_fields ++ @group_invitation_optional_fields)
    |> validate_required(@group_invitation_required_fields)
    |> validate_inclusion(:status, @group_invitation_valid_statuses)
  end

  @visibility_grant_required_fields [:resource_type, :resource_id, :granted_to_id, :granted_by_id]
  @visibility_grant_optional_fields []

  @doc "Changeset for creating a visibility grant."
  def visibility_grant_changeset(grant, attrs) do
    grant
    |> cast(attrs, @visibility_grant_required_fields ++ @visibility_grant_optional_fields)
    |> validate_required(@visibility_grant_required_fields)
    |> unique_constraint([:resource_type, :resource_id, :granted_to_id])
  end

  @user_block_required_fields [:blocker_id, :blocked_id]
  @user_block_optional_fields []

  @doc "Changeset for creating a user block."
  def user_block_changeset(user_block, attrs) do
    user_block
    |> cast(attrs, @user_block_required_fields ++ @user_block_optional_fields)
    |> validate_required(@user_block_required_fields)
    |> unique_constraint([:blocker_id, :blocked_id])
  end

  @doc """
  Blocks a user. Inserts a row into op.user_blocks and emits a
  `social.user_blocked` event.

  Returns `{:ok, block}` on success or `{:error, changeset}` if the
  constraint is violated (e.g. duplicate block).
  """
  @spec block_user(String.t(), String.t()) :: {:ok, UserBlock.t()} | {:error, Ecto.Changeset.t()}
  def block_user(blocker_id, blocked_id) do
    result =
      %UserBlock{}
      |> user_block_changeset(%{blocker_id: blocker_id, blocked_id: blocked_id})
      |> Repo.insert()

    case result do
      {:ok, block} ->
        Events.emit_safe(%{
          event_type: "social.user_blocked",
          aggregate_type: "user",
          aggregate_id: blocker_id,
          payload: %{blocked_id: blocked_id}
        })

        {:ok, block}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Unblocks a user. Deletes the block row from op.user_blocks and emits a
  `social.user_unblocked` event.

  Returns `{:ok, :unblocked}` on success or `{:error, :not_found}` if no
  block record exists.
  """
  @spec unblock_user(String.t(), String.t()) :: {:ok, :unblocked} | {:error, :not_found}
  def unblock_user(blocker_id, blocked_id) do
    query =
      from(b in UserBlock,
        where: b.blocker_id == ^blocker_id and b.blocked_id == ^blocked_id
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      block ->
        Repo.delete!(block)

        Events.emit_safe(%{
          event_type: "social.user_unblocked",
          aggregate_type: "user",
          aggregate_id: blocker_id,
          payload: %{blocked_id: blocked_id}
        })

        {:ok, :unblocked}
    end
  end

  @doc """
  Returns a paginated list of users blocked by `blocker_id`, along with the total count.

  Each entry is a map with `:id`, `:display_name`, and `:blocked_at`.
  """
  @spec list_blocked_users(String.t(), keyword()) :: {[map()], non_neg_integer()}
  def list_blocked_users(blocker_id, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = 20

    base =
      from b in UserBlock,
        join: u in User,
        on: u.id == b.blocked_id,
        where: b.blocker_id == ^blocker_id,
        select: %{id: u.id, display_name: u.display_name, blocked_at: b.created_at},
        order_by: [desc: b.created_at]

    total = Repo.aggregate(base, :count)

    blocked =
      base
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    {blocked, total}
  end

  @doc """
  Returns true if either user has blocked the other (bidirectional check).

  `blocked?(viewer_id, owner_id)` returns true if viewer blocked owner
  OR owner blocked viewer.
  """
  @spec blocked?(String.t(), String.t()) :: boolean()
  def blocked?(viewer_id, owner_id) do
    Repo.exists?(
      from(b in UserBlock,
        where:
          (b.blocker_id == ^viewer_id and b.blocked_id == ^owner_id) or
            (b.blocker_id == ^owner_id and b.blocked_id == ^viewer_id)
      )
    )
  end

  @doc """
  Returns true only if the viewer has blocked the owner (one direction).

  `blocked_by?(viewer_id, owner_id)` returns true if viewer is the blocker
  and owner is the blocked user.
  """
  @spec blocked_by?(String.t(), String.t()) :: boolean()
  def blocked_by?(viewer_id, owner_id) do
    Repo.exists?(
      from(b in UserBlock,
        where: b.blocker_id == ^viewer_id and b.blocked_id == ^owner_id
      )
    )
  end
end
