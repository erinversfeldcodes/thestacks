defmodule Stacks.Visibility do
  @moduledoc "Authoritative visibility gate for all content read paths."

  # load_user/1 has a defensive catch-all clause that dialyzer considers
  # unreachable because the only call site already matches %{user_id: _}.
  # The fallback is intentional safety — suppress the warning.
  @dialyzer {:nowarn_function, load_user: 1}

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Shelving.{Bookshelf, Placement}
  alias Stacks.Social

  # Visibility order: 0 = most permissive (public), 2 = most restrictive (owner).
  # A child resource must be equally or more restrictive than its parent.
  @visibility_rank %{"public" => 0, "platform" => 1, "owner" => 2}

  @doc """
  Resolves whether a resource is visible to a viewer.

  Viewer types:
  - `:unauthenticated` — not logged in
  - `{:platform_user, user_id}` — logged-in platform user

  Returns `:visible` or `:hidden`. Always returns `:hidden` on nil resource
  or unknown viewer types — never raises.
  """
  @spec resolve_visibility(term(), term()) :: :visible | :hidden
  def resolve_visibility(nil, _viewer), do: :hidden

  def resolve_visibility(%Placement{} = placement, {:platform_user, viewer_id} = viewer) do
    placement = maybe_preload_bookshelf(placement)

    if marketplace_exception?(placement) do
      :visible
    else
      do_resolve(placement, viewer, viewer_id)
    end
  end

  def resolve_visibility(%Placement{} = placement, :unauthenticated) do
    placement = maybe_preload_bookshelf(placement)
    do_resolve(placement, :unauthenticated, nil)
  end

  def resolve_visibility(resource, {:platform_user, viewer_id} = viewer) do
    do_resolve(resource, viewer, viewer_id)
  end

  def resolve_visibility(resource, :unauthenticated) do
    do_resolve(resource, :unauthenticated, nil)
  end

  def resolve_visibility(_resource, _viewer), do: :hidden

  # ---------------------------------------------------------------------------
  # Internal resolution logic
  # ---------------------------------------------------------------------------

  defp do_resolve(resource, viewer, viewer_id) do
    owner_id = get_owner_id(resource)

    with :ok <- check_profile_ceiling(resource, owner_id, viewer, viewer_id),
         :ok <- check_block(owner_id, viewer_id),
         :ok <- check_age_gate(resource, viewer_id),
         :ok <- check_resource_visibility(resource, owner_id, viewer, viewer_id) do
      :visible
    else
      :hidden -> :hidden
    end
  end

  # ---------------------------------------------------------------------------
  # Profile ceiling check
  #
  # Only `profile_visibility: "owner"` acts as a ceiling — it hides all content
  # from any viewer who is not the resource owner. A `"platform"` profile does
  # not add any restriction beyond the resource's own visibility setting.
  # ---------------------------------------------------------------------------

  defp check_profile_ceiling(_resource, nil, _viewer, _viewer_id), do: :ok

  defp check_profile_ceiling(_resource, owner_id, {:platform_user, viewer_id}, _viewer_id_arg)
       when owner_id == viewer_id,
       do: :ok

  defp check_profile_ceiling(resource, owner_id, viewer, _viewer_id) do
    profile_visibility = load_profile_visibility(resource, owner_id)

    case {profile_visibility, viewer} do
      {"owner", _} -> :hidden
      _ -> :ok
    end
  end

  defp load_profile_visibility(%{user_id: _} = resource, _owner_id) do
    owner = load_user(resource)
    if owner, do: owner.profile_visibility, else: "owner"
  end

  defp load_profile_visibility(%Placement{} = placement, _owner_id) do
    case placement.bookshelf do
      %{user_id: user_id} when not is_nil(user_id) ->
        owner = Accounts.get_user(user_id)
        if owner, do: owner.profile_visibility, else: "owner"

      _ ->
        "owner"
    end
  end

  defp load_profile_visibility(_resource, _owner_id), do: nil

  # ---------------------------------------------------------------------------
  # Block check (bidirectional)
  # ---------------------------------------------------------------------------

  defp check_block(_owner_id, nil), do: :ok
  defp check_block(nil, _viewer_id), do: :ok

  defp check_block(owner_id, viewer_id) do
    if Social.blocked?(viewer_id, owner_id) do
      :hidden
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Age gate check
  # ---------------------------------------------------------------------------

  defp check_age_gate(%{visibility_tier: "age_gated"}, nil), do: :hidden

  defp check_age_gate(%{visibility_tier: "age_gated"}, viewer_id) do
    viewer = Accounts.get_user(viewer_id)

    if viewer && viewer.age_verified do
      :ok
    else
      :hidden
    end
  end

  defp check_age_gate(_resource, _viewer_id), do: :ok

  # ---------------------------------------------------------------------------
  # Resource-level visibility check
  #
  # Visibility values:
  #   "public"   — visible to everyone including unauthenticated
  #   "platform" — visible to everyone including unauthenticated (open platform)
  #   "owner"    — visible only to the resource owner
  #   "group"    — visible to members of the associated group
  #
  # For resources with only a `visibility_tier` (Books), treat as "public"
  # since the age gate handles age-gated restrictions separately.
  # ---------------------------------------------------------------------------

  defp check_resource_visibility(resource, owner_id, viewer, viewer_id) do
    visibility = get_resource_visibility(resource)

    case {visibility, viewer} do
      {"public", _} ->
        :ok

      {"platform", _} ->
        :ok

      {"owner", {:platform_user, vid}} when vid == owner_id ->
        :ok

      {"owner", _} ->
        :hidden

      {"group", {:platform_user, vid}} ->
        check_group_visibility(resource, vid)

      {"group", _} ->
        :hidden

      _ ->
        check_default_visibility(owner_id, viewer_id)
    end
  end

  defp check_default_visibility(owner_id, viewer_id) when owner_id == viewer_id, do: :ok
  defp check_default_visibility(_owner_id, _viewer_id), do: :hidden

  defp check_group_visibility(_resource, _viewer_id), do: :hidden

  # ---------------------------------------------------------------------------
  # Marketplace exception
  # ---------------------------------------------------------------------------

  defp marketplace_exception?(%Placement{listing_status: "active"} = placement) do
    case placement.bookshelf do
      %Bookshelf{name: "looking_for_home"} -> true
      _ -> false
    end
  end

  defp marketplace_exception?(_), do: false

  # ---------------------------------------------------------------------------
  # Helpers to extract owner_id and resource visibility
  # ---------------------------------------------------------------------------

  defp get_owner_id(%{user_id: user_id}), do: user_id

  defp get_owner_id(%Placement{} = placement) do
    case placement.bookshelf do
      %{user_id: user_id} -> user_id
      _ -> nil
    end
  end

  defp get_owner_id(_), do: nil

  # Bookshelves and Placements have a `visibility` field.
  defp get_resource_visibility(%{visibility: visibility}), do: visibility

  # Books (and similar catalog resources) have `visibility_tier` instead of
  # `visibility`. The age gate check handles age restrictions; at the
  # resource-visibility level, catalog entries are effectively public.
  defp get_resource_visibility(%{visibility_tier: _}), do: "public"

  defp get_resource_visibility(_), do: "owner"

  defp load_user(%{user_id: user_id}), do: Accounts.get_user(user_id)
  defp load_user(_), do: nil

  defp maybe_preload_bookshelf(%Placement{bookshelf: %Bookshelf{}} = placement), do: placement

  defp maybe_preload_bookshelf(%Placement{} = placement) do
    Repo.preload(placement, :bookshelf)
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns true if the viewer can see the resource, false otherwise.
  """
  @spec can_view?(term(), term()) :: boolean()
  def can_view?(resource, viewer), do: resolve_visibility(resource, viewer) == :visible

  @doc """
  Returns all bookshelves for the given user_id that are visible to the viewer.
  """
  @spec viewable_shelves(String.t(), term()) :: [Bookshelf.t()]
  def viewable_shelves(user_id, viewer) do
    Bookshelf
    |> where([b], b.user_id == ^user_id)
    |> Repo.all()
    |> Enum.filter(&can_view?(&1, viewer))
  end

  @doc """
  Returns all placements for the given bookshelf_id that are visible to the viewer.
  """
  @spec viewable_placements(String.t(), term()) :: [Placement.t()]
  def viewable_placements(shelf_id, viewer) do
    Placement
    |> where([p], p.bookshelf_id == ^shelf_id)
    |> Repo.all()
    |> Enum.filter(&can_view?(&1, viewer))
  end

  @doc """
  Validates that a child resource visibility is not less restrictive than the
  parent resource visibility.

  Visibility order (most permissive to most restrictive):
  `"public"` (0) < `"platform"` (1) < `"owner"` (2).

  A child resource must have an equal or higher rank than its parent.
  Returns `:ok` if valid, or `{:error, reason}` if the child would expose
  more than the parent allows.
  """
  @spec validate_visibility_ceiling(String.t(), String.t(), atom()) ::
          :ok | {:error, String.t()}
  def validate_visibility_ceiling(child_visibility, parent_visibility, resource_type) do
    child_rank = Map.get(@visibility_rank, child_visibility, 0)
    parent_rank = Map.get(@visibility_rank, parent_visibility, 0)

    if child_rank >= parent_rank do
      :ok
    else
      {:error,
       "#{resource_type} visibility '#{child_visibility}' is less restrictive than parent visibility '#{parent_visibility}'"}
    end
  end
end
