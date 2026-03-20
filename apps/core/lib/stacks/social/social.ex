defmodule Stacks.Social do
  @moduledoc """
  Context for social features: user blocks, groups, group membership,
  group invitations, and visibility grants.
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Accounts.User
  alias Stacks.Events
  alias Stacks.Social.{Group, GroupInvitation, GroupMember, UserBlock, VisibilityGrant}

  _ = Group
  _ = GroupMember
  _ = GroupInvitation
  _ = VisibilityGrant

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
      |> UserBlock.changeset(%{blocker_id: blocker_id, blocked_id: blocked_id})
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
