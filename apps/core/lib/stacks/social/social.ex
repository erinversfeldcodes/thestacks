defmodule Stacks.Social do
  @moduledoc """
  Context for social features: user blocks, groups, group membership,
  group invitations, and visibility grants.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Core.Repo
  alias Ecto.Multi
  alias Stacks.Accounts.User
  alias Stacks.Blog.Post
  alias Stacks.Books.Book
  alias Stacks.Events
  alias Stacks.Shelving.{Bookshelf, Placement}
  alias Stacks.Social.{Group, GroupInvitation, GroupMember, UserBlock, VisibilityGrant}

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
    |> validate_inclusion(:resource_type, ["bookshelf"])
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
        :telemetry.execute([:stacks, :social, :block], %{count: 1}, %{})

        Events.emit_safe(%{
          event_type: "social.user_blocked",
          aggregate_type: "user",
          aggregate_id: blocker_id,
          payload: %{blocked_id: blocked_id}
        })

        {:ok, block}

      {:error, changeset} ->
        # Tag the counter by the ACTUAL failure. A uniqueness violation is the
        # expected duplicate/already-blocked case; anything else (e.g. a missing
        # required id) must not be mislabeled as :already_blocked.
        :telemetry.execute(
          [:stacks, :social, :block_error],
          %{count: 1},
          %{reason: block_error_reason(changeset)}
        )

        {:error, changeset}
    end
  end

  # Classifies a block-insert changeset error for the block_error counter.
  # The (blocker_id, blocked_id) unique_constraint is the only DB constraint, so
  # a unique violation is :already_blocked; any other changeset error is :invalid.
  @spec block_error_reason(Ecto.Changeset.t()) :: :already_blocked | :invalid
  defp block_error_reason(%Ecto.Changeset{errors: errors}) do
    unique? =
      Enum.any?(errors, fn {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique end)

    if unique?, do: :already_blocked, else: :invalid
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
        {:ok, _} = Repo.delete(block)

        :telemetry.execute([:stacks, :social, :unblock], %{count: 1}, %{})

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
  Returns the IDs of all users blocked by the given user.
  """
  @spec blocked_user_ids(binary()) :: [binary()]
  def blocked_user_ids(user_id) do
    Repo.all(
      from(b in UserBlock,
        where: b.blocker_id == ^user_id,
        select: b.blocked_id
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

  # ── Group CRUD ──

  # Dialyzer false positive: Ecto.Multi callback form confuses opaque MapSet tracking.
  @dialyzer {:no_opaque, create_group: 2}
  @doc """
  Creates a group and inserts the owner as the first member.
  Emits a `group.created` event.
  """
  def create_group(owner_id, attrs) do
    attrs = Map.merge(attrs, %{owner_id: owner_id})
    group_cs = group_changeset(%Group{}, attrs)

    result =
      Multi.new()
      |> Multi.insert(:group, group_cs)
      |> Multi.insert(:member, fn %{group: group} ->
        group_member_changeset(%GroupMember{}, %{
          group_id: group.id,
          user_id: owner_id,
          role: "member",
          joined_at: DateTime.utc_now()
        })
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{group: group}} ->
        Events.emit_safe(%{
          event_type: "group.created",
          aggregate_type: "group",
          aggregate_id: group.id,
          payload: %{owner_id: owner_id}
        })

        {:ok, group}

      {:error, :group, changeset, _} ->
        {:error, changeset}

      {:error, :member, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Returns a group if the viewer is authorized to see it.
  Platform-visible groups are accessible to any viewer; invite-only groups only to members.
  """
  def get_group(group_id, viewer_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        if group.visibility == "platform" or member?(group.id, viewer_id) do
          group
        else
          nil
        end
    end
  end

  @doc "Returns all groups where user is a member."
  def list_user_groups(user_id) do
    from(g in Group,
      join: m in GroupMember,
      on: m.group_id == g.id,
      where: m.user_id == ^user_id,
      order_by: [desc: g.created_at]
    )
    |> Repo.all()
  end

  @doc "Updates group attrs. Only the owner may update."
  def update_group(group_id, caller_id, attrs) do
    case Repo.get(Group, group_id) do
      nil ->
        {:error, :not_found}

      %Group{owner_id: ^caller_id} = group ->
        group
        |> group_changeset(attrs)
        |> Repo.update()

      _group ->
        {:error, :unauthorized}
    end
  end

  @doc "Deletes a group. Only the owner may delete."
  def delete_group(group_id, caller_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :not_found}
      %Group{owner_id: ^caller_id} = group -> Repo.delete(group)
      _group -> {:error, :unauthorized}
    end
  end

  # ── Invitation Flow ──

  @doc """
  Invites a user to a group by email or display_name.
  Emits `group.invitation_sent` event.
  """
  def invite_member(group_id, inviter_id, invitee_identifier) do
    with :ok <- if(member?(group_id, inviter_id), do: :ok, else: {:error, :unauthorized}),
         {:ok, invitee} <- resolve_invitee(invitee_identifier),
         :ok <- if(member?(group_id, invitee.id), do: {:error, :already_member}, else: :ok),
         :ok <-
           if(pending_invitation?(group_id, invitee.id),
             do: {:error, :already_invited},
             else: :ok
           ) do
      result =
        %GroupInvitation{}
        |> group_invitation_changeset(%{
          group_id: group_id,
          invited_by_id: inviter_id,
          invited_user_id: invitee.id,
          status: "pending"
        })
        |> Repo.insert()

      case result do
        {:ok, invitation} ->
          Events.emit_safe(%{
            event_type: "group.invitation_sent",
            aggregate_type: "group",
            aggregate_id: group_id,
            payload: %{invited_user_id: invitee.id, invited_by_id: inviter_id}
          })

          {:ok, invitation}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  # Dialyzer false positive: Ecto.Multi callback form confuses opaque MapSet tracking.
  @dialyzer {:no_opaque, accept_invitation: 2}
  @doc """
  Accepts a pending invitation. Atomically creates a GroupMember and updates invitation status.
  Emits `group.member_joined` event.
  """
  def accept_invitation(invitation_id, user_id) do
    case Repo.get(GroupInvitation, invitation_id) do
      nil ->
        {:error, :not_found}

      %GroupInvitation{invited_user_id: invited_id} when invited_id != user_id ->
        {:error, :unauthorized}

      %GroupInvitation{status: "pending"} = invitation ->
        now = DateTime.utc_now()

        result =
          Multi.new()
          |> Multi.update(
            :invitation,
            group_invitation_changeset(invitation, %{status: "accepted", responded_at: now})
          )
          |> Multi.insert(
            :member,
            group_member_changeset(%GroupMember{}, %{
              group_id: invitation.group_id,
              user_id: user_id,
              role: "member",
              joined_at: now
            })
          )
          |> Repo.transaction()

        case result do
          {:ok, %{invitation: updated_invitation}} ->
            Events.emit_safe(%{
              event_type: "group.member_joined",
              aggregate_type: "group",
              aggregate_id: invitation.group_id,
              payload: %{user_id: user_id}
            })

            {:ok, updated_invitation}

          {:error, _step, changeset, _changes} ->
            {:error, changeset}
        end

      _non_pending ->
        {:error, :not_found}
    end
  end

  @doc "Declines a pending invitation."
  def decline_invitation(invitation_id, user_id) do
    case Repo.get(GroupInvitation, invitation_id) do
      nil ->
        {:error, :not_found}

      %GroupInvitation{invited_user_id: invited_id} when invited_id != user_id ->
        {:error, :unauthorized}

      %GroupInvitation{status: "pending"} = invitation ->
        invitation
        |> group_invitation_changeset(%{status: "declined", responded_at: DateTime.utc_now()})
        |> Repo.update()

      _non_pending ->
        {:error, :not_found}
    end
  end

  # ── Member Management ──

  @doc "Removes caller from group. Owner cannot leave."
  def leave_group(group_id, caller_id) do
    group = Repo.get(Group, group_id)

    cond do
      is_nil(group) ->
        {:error, :not_member}

      group.owner_id == caller_id ->
        {:error, :is_owner}

      true ->
        case get_membership(group_id, caller_id) do
          nil ->
            {:error, :not_member}

          membership ->
            {:ok, _} = Repo.delete(membership)

            Events.emit_safe(%{
              event_type: "group.member_left",
              aggregate_type: "group",
              aggregate_id: group_id,
              payload: %{user_id: caller_id}
            })

            {:ok, :left}
        end
    end
  end

  @doc "Owner removes another member. Emits `group.member_removed` event."
  def remove_member(group_id, caller_id, member_user_id) do
    case Repo.get(Group, group_id) do
      nil ->
        {:error, :not_found}

      %Group{owner_id: ^caller_id} ->
        case get_membership(group_id, member_user_id) do
          nil ->
            {:error, :not_found}

          membership ->
            {:ok, _} = Repo.delete(membership)

            Events.emit_safe(%{
              event_type: "group.member_removed",
              aggregate_type: "group",
              aggregate_id: group_id,
              payload: %{removed_user_id: member_user_id, removed_by_id: caller_id}
            })

            {:ok, :removed}
        end

      _group ->
        {:error, :unauthorized}
    end
  end

  @doc "Returns members list. Checks viewer authorization."
  def list_group_members(group_id, viewer_id) do
    case Repo.get(Group, group_id) do
      nil ->
        {:error, :not_found}

      group ->
        if group.visibility == "platform" or member?(group.id, viewer_id) do
          members =
            from(m in GroupMember,
              where: m.group_id == ^group_id,
              join: u in User,
              on: u.id == m.user_id,
              select: %{
                user_id: m.user_id,
                role: m.role,
                display_name: u.display_name,
                joined_at: m.joined_at
              },
              order_by: [asc: m.joined_at]
            )
            |> Repo.all()

          {:ok, members}
        else
          {:error, :unauthorized}
        end
    end
  end

  # ── Visibility Grants ──

  @doc """
  Grants visibility to a user for a group-visibility bookshelf.
  Returns {:error, :not_applicable} if bookshelf visibility != "group".
  Returns {:error, :unauthorized} if caller does not own the bookshelf.
  Returns {:error, :already_granted} if grant already exists.
  """
  def grant_visibility(bookshelf_id, caller_id, grantee_user_id) do
    case Repo.get(Bookshelf, bookshelf_id) do
      nil ->
        {:error, :not_found}

      %Bookshelf{user_id: user_id} when user_id != caller_id ->
        {:error, :unauthorized}

      %Bookshelf{visibility: visibility} when visibility != "group" ->
        {:error, :not_applicable}

      %Bookshelf{} ->
        result =
          %VisibilityGrant{}
          |> visibility_grant_changeset(%{
            resource_type: "bookshelf",
            resource_id: bookshelf_id,
            granted_to_id: grantee_user_id,
            granted_by_id: caller_id
          })
          |> Repo.insert()

        case result do
          {:ok, grant} -> {:ok, grant}
          {:error, _changeset} -> {:error, :already_granted}
        end
    end
  end

  @doc """
  Revokes a visibility grant. Returns {:error, :unauthorized} if caller doesn't own the bookshelf.
  Returns {:error, :not_found} if no grant exists.
  """
  def revoke_visibility(bookshelf_id, caller_id, grantee_user_id) do
    case Repo.get(Bookshelf, bookshelf_id) do
      nil ->
        {:error, :not_found}

      %Bookshelf{user_id: user_id} when user_id != caller_id ->
        {:error, :unauthorized}

      %Bookshelf{} ->
        query =
          from(g in VisibilityGrant,
            where:
              g.resource_type == "bookshelf" and
                g.resource_id == ^bookshelf_id and
                g.granted_to_id == ^grantee_user_id
          )

        case Repo.one(query) do
          nil ->
            {:error, :not_found}

          grant ->
            Repo.delete(grant)
            :ok
        end
    end
  end

  @doc """
  Lists all visibility grants for a bookshelf. Returns {:error, :unauthorized} if caller doesn't own bookshelf.
  """
  def list_visibility_grants(bookshelf_id, caller_id) do
    case Repo.get(Bookshelf, bookshelf_id) do
      nil ->
        {:error, :not_found}

      %Bookshelf{user_id: user_id} when user_id != caller_id ->
        {:error, :unauthorized}

      %Bookshelf{} ->
        grants =
          from(g in VisibilityGrant,
            where: g.resource_type == "bookshelf" and g.resource_id == ^bookshelf_id,
            order_by: [desc: g.created_at]
          )
          |> Repo.all()

        {:ok, grants}
    end
  end

  @doc """
  Returns true if viewer_id has an explicit visibility grant for the given bookshelf_id.
  """
  def has_visibility_grant?(bookshelf_id, viewer_id) do
    Repo.exists?(
      from(g in VisibilityGrant,
        where:
          g.resource_type == "bookshelf" and
            g.resource_id == ^bookshelf_id and
            g.granted_to_id == ^viewer_id
      )
    )
  end

  # ── Group Content Feed ──

  @doc """
  Returns a reverse-chronological feed of activity from group members.

  Combines placements and blog posts visible at the "group" or "platform" level.
  Supports cursor-based pagination via the `:before` option (DateTime) and
  `:limit` (integer, default 20, max 50).

  Returns `{:error, :not_found}` if the group does not exist,
  `{:error, :unauthorized}` if the viewer is not a member.
  """
  @spec feed_for_group(String.t(), String.t(), keyword()) ::
          {:ok, list(map())} | {:error, :not_found | :unauthorized}
  def feed_for_group(group_id, viewer_id, opts \\ []) do
    case Repo.get(Group, group_id) do
      nil ->
        {:error, :not_found}

      _group ->
        if member?(group_id, viewer_id) do
          build_feed(group_id, viewer_id, opts)
        else
          {:error, :unauthorized}
        end
    end
  end

  defp build_feed(group_id, viewer_id, opts) do
    limit = min(Keyword.get(opts, :limit, 20), 50)
    before_dt = Keyword.get(opts, :before)
    blocked_ids = blocked_user_ids(viewer_id)

    member_ids =
      from(m in GroupMember, where: m.group_id == ^group_id, select: m.user_id)
      |> Repo.all()
      |> Enum.reject(&(&1 in blocked_ids))

    if member_ids == [] do
      {:ok, []}
    else
      placement_items = feed_placements(member_ids, before_dt, limit)
      post_items = feed_posts(member_ids, before_dt, limit)

      items =
        (placement_items ++ post_items)
        |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
        |> Enum.take(limit)

      {:ok, items}
    end
  end

  defp feed_placements(member_ids, before_dt, limit) do
    base =
      from(p in Placement,
        join: bs in Bookshelf,
        on: p.bookshelf_id == bs.id,
        join: b in Book,
        on: p.book_id == b.id,
        join: u in User,
        on: bs.user_id == u.id,
        where: bs.user_id in ^member_ids,
        where: p.visibility in ["group", "platform"],
        where: is_nil(p.removed_at),
        order_by: [desc: p.placed_at],
        limit: ^limit,
        select: %{
          type: :placement_created,
          placement_id: p.id,
          book_id: b.id,
          book_title: b.title,
          user_id: u.id,
          user_display_name: u.display_name,
          occurred_at: p.placed_at
        }
      )

    base =
      if before_dt do
        from [p, ...] in base, where: p.placed_at < ^before_dt
      else
        base
      end

    Repo.all(base)
  end

  defp feed_posts(member_ids, before_dt, limit) do
    base =
      from(post in Post,
        join: u in User,
        on: post.user_id == u.id,
        where: post.user_id in ^member_ids,
        where: post.visibility in ["group", "platform"],
        where: not is_nil(post.published_at),
        order_by: [desc: post.published_at],
        limit: ^limit,
        select: %{
          type: :blog_post,
          post_id: post.id,
          post_title: post.title,
          post_visibility: post.visibility,
          user_id: u.id,
          user_display_name: u.display_name,
          occurred_at: post.published_at
        }
      )

    base =
      if before_dt do
        from [post, ...] in base, where: post.published_at < ^before_dt
      else
        base
      end

    Repo.all(base)
  end

  # ── Private Helpers ──

  @doc "Returns true if user_id is a member of group_id."
  def group_member?(group_id, user_id) do
    Repo.exists?(from(m in GroupMember, where: m.group_id == ^group_id and m.user_id == ^user_id))
  end

  defp member?(group_id, user_id), do: group_member?(group_id, user_id)

  defp get_membership(group_id, user_id) do
    Repo.one(from(m in GroupMember, where: m.group_id == ^group_id and m.user_id == ^user_id))
  end

  defp resolve_invitee(identifier) do
    # Prioritise exact email match; fall back to display_name.
    user =
      Repo.one(from(u in User, where: u.email == ^identifier, limit: 1)) ||
        Repo.one(from(u in User, where: u.display_name == ^identifier, limit: 1))

    case user do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp pending_invitation?(group_id, user_id) do
    Repo.exists?(
      from(i in GroupInvitation,
        where: i.group_id == ^group_id and i.invited_user_id == ^user_id and i.status == "pending"
      )
    )
  end
end
