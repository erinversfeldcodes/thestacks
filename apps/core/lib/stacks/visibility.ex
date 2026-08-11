defmodule Stacks.Visibility do
  @moduledoc "Authoritative visibility gate for all content read paths."

  @dialyzer {:nowarn_function, load_user: 1}

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Shelving.{Bookshelf, Placement}
  alias Stacks.Social

  @audience_exposure %{"owner" => 0, "group" => 1, "platform" => 2, "public" => 3}

  @audience_levels ~w(owner group platform public)

  # Audience levels settable on a USER PROFILE — owner / platform / public. `group`
  # ("friends-only") profiles are deferred to #224 (need a chosen-group FK), so the
  # rung is not offered here yet. Used by BOTH profile registration and
  # settings-update, keeping them consistent.
  @profile_audience_levels ~w(owner platform public)

  @ceiling_resource_types [:bookshelf, :placement, :post]

  @doc """
  Resolves whether a resource is visible to a viewer.

  Viewer types:
  - `:unauthenticated` — not logged in
  - `{:platform_user, user_id}` — logged-in platform user
  - `:platform_preview` — a generic authenticated platform user with NO identity
    (never the owner, in no groups, no block relationship). Used by the ViewAs
    `platform` perspective so a resource owner previewing "as a platform user"
    does not see their own owner-only content.

  Returns `:visible` or `:hidden`. Always returns `:hidden` on nil resource
  or unknown viewer types — never raises.
  """
  @spec resolve_visibility(term(), term()) :: :visible | :hidden
  def resolve_visibility(nil, _viewer), do: :hidden

  def resolve_visibility(%Placement{} = placement, {:platform_user, _} = viewer) do
    placement
    |> maybe_preload_bookshelf()
    |> resolve_placement(viewer, nil)
  end

  def resolve_visibility(%Placement{} = placement, :platform_preview) do
    placement
    |> maybe_preload_bookshelf()
    |> resolve_placement(:platform_preview, nil)
  end

  def resolve_visibility(%Placement{} = placement, :unauthenticated) do
    placement
    |> maybe_preload_bookshelf()
    |> resolve_placement(:unauthenticated, nil)
  end

  def resolve_visibility(resource, {:platform_user, viewer_id} = viewer) do
    do_resolve(resource, viewer, viewer_id, nil)
  end

  def resolve_visibility(resource, :platform_preview) do
    do_resolve(resource, :platform_preview, nil, nil)
  end

  def resolve_visibility(resource, :unauthenticated) do
    do_resolve(resource, :unauthenticated, nil, nil)
  end

  def resolve_visibility(_resource, _viewer), do: :hidden

  defp resolve_placement(%Placement{} = placement, {:platform_user, viewer_id} = viewer, ctx) do
    if marketplace_exception?(placement) do
      case check_block(get_owner_id(placement), viewer_id, ctx) do
        :ok -> :visible
        :hidden -> :hidden
      end
    else
      do_resolve(placement, viewer, viewer_id, ctx)
    end
  end

  defp resolve_placement(%Placement{} = placement, :platform_preview, ctx) do
    if marketplace_exception?(placement),
      do: :visible,
      else: do_resolve(placement, :platform_preview, nil, ctx)
  end

  defp resolve_placement(%Placement{} = placement, :unauthenticated, ctx) do
    do_resolve(placement, :unauthenticated, nil, ctx)
  end

  defp resolve_placement(_placement, _viewer, _ctx), do: :hidden

  defp do_resolve(resource, viewer, viewer_id, ctx) do
    owner_id = get_owner_id(resource)

    with :ok <- check_profile_ceiling(resource, owner_id, viewer, viewer_id),
         :ok <- check_block(owner_id, viewer_id, ctx),
         :ok <- check_age_gate(resource, viewer_id, ctx),
         :ok <- check_resource_visibility(resource, owner_id, viewer, viewer_id) do
      :visible
    else
      :hidden -> :hidden
    end
  end

  defp check_profile_ceiling(_resource, nil, _viewer, _viewer_id), do: :ok

  defp check_profile_ceiling(_resource, owner_id, {:platform_user, viewer_id}, _viewer_id_arg)
       when owner_id == viewer_id,
       do: :ok

  defp check_profile_ceiling(resource, owner_id, viewer, _viewer_id) do
    profile_visibility = load_profile_visibility(resource, owner_id)

    case {profile_visibility, viewer} do
      {"owner", _} -> :hidden
      {"platform", :unauthenticated} -> :hidden
      _ -> :ok
    end
  end

  defp load_profile_visibility(%{user_id: _} = resource, _owner_id) do
    owner = load_user(resource)
    if owner, do: owner.profile_visibility, else: "owner"
  end

  defp load_profile_visibility(%Placement{} = placement, _owner_id) do
    case placement.bookshelf do
      %{user: %{profile_visibility: pv}} when is_binary(pv) ->
        pv

      %{user_id: user_id} when not is_nil(user_id) ->
        owner = Accounts.get_user(user_id)
        if owner, do: owner.profile_visibility, else: "owner"

      _ ->
        "owner"
    end
  end

  defp load_profile_visibility(_resource, _owner_id), do: nil

  defp check_block(_owner_id, nil, _ctx), do: :ok
  defp check_block(nil, _viewer_id, _ctx), do: :ok

  defp check_block(owner_id, viewer_id, ctx) do
    if blocked_pair?(owner_id, viewer_id, ctx) do
      :hidden
    else
      :ok
    end
  end

  defp blocked_pair?(owner_id, viewer_id, nil), do: Social.blocked?(viewer_id, owner_id)

  defp blocked_pair?(owner_id, viewer_id, %{blocks: blocks}) do
    case Map.fetch(blocks, owner_id) do
      {:ok, blocked?} -> blocked?
      :error -> Social.blocked?(viewer_id, owner_id)
    end
  end

  defp check_age_gate(%Placement{} = placement, viewer_id, ctx) do
    placement = maybe_preload_book(placement)

    cond do
      not Stacks.FeatureFlags.age_gating_enabled?() -> :ok
      not age_gated_book?(placement.book) -> :ok
      not is_nil(viewer_id) and get_owner_id(placement) == viewer_id -> :ok
      viewer_age_verified?(viewer_id, ctx) -> :ok
      true -> :hidden
    end
  end

  defp check_age_gate(%{visibility_tier: "age_gated"}, viewer_id, ctx) do
    cond do
      not Stacks.FeatureFlags.age_gating_enabled?() -> :ok
      viewer_age_verified?(viewer_id, ctx) -> :ok
      true -> :hidden
    end
  end

  defp check_age_gate(_resource, _viewer_id, _ctx), do: :ok

  defp viewer_age_verified?(_viewer_id, %{age_verified: verified?}), do: verified?
  defp viewer_age_verified?(viewer_id, nil), do: viewer_age_verified?(viewer_id)

  defp viewer_age_verified?(nil), do: false

  defp viewer_age_verified?(viewer_id) do
    case Accounts.get_user(viewer_id) do
      %{age_verified: true} -> true
      _ -> false
    end
  end

  defp age_gated_book?(%{visibility_tier: "age_gated"}), do: true
  defp age_gated_book?(_), do: false

  defp maybe_preload_book(%Placement{} = placement) do
    case placement.book do
      %Ecto.Association.NotLoaded{} -> Repo.preload(placement, :book)
      _ -> placement
    end
  end

  defp check_resource_visibility(resource, owner_id, viewer, viewer_id) do
    visibility = get_resource_visibility(resource)

    case {visibility, viewer} do
      {"public", _} ->
        :ok

      {"platform", v} ->
        check_platform_audience(v)

      {"owner", {:platform_user, vid}} when vid == owner_id ->
        :ok

      {"owner", _} ->
        :hidden

      {"group", {:platform_user, vid}} when vid == owner_id ->
        :ok

      {"group", {:platform_user, vid}} ->
        check_group_visibility(resource, vid)

      {"group", _} ->
        :hidden

      _ ->
        check_default_visibility(owner_id, viewer_id)
    end
  end

  defp check_platform_audience({:platform_user, _}), do: :ok
  defp check_platform_audience(:platform_preview), do: :ok
  defp check_platform_audience(_), do: :hidden

  defp check_default_visibility(owner_id, viewer_id) when owner_id == viewer_id, do: :ok
  defp check_default_visibility(_owner_id, _viewer_id), do: :hidden

  defp check_group_visibility(
         %Placement{bookshelf: %Bookshelf{visibility_group_id: gid}},
         viewer_id
       )
       when not is_nil(gid) do
    if Social.group_member?(gid, viewer_id), do: :ok, else: :hidden
  end

  defp check_group_visibility(%Placement{}, _viewer_id), do: :hidden

  defp check_group_visibility(%{visibility_group_id: gid}, viewer_id) when not is_nil(gid) do
    if Social.group_member?(gid, viewer_id), do: :ok, else: :hidden
  end

  defp check_group_visibility(_resource, _viewer_id), do: :hidden

  defp marketplace_exception?(%Placement{listing_status: "active"} = placement) do
    case placement.bookshelf do
      %Bookshelf{name: "looking_for_home"} -> true
      _ -> false
    end
  end

  defp marketplace_exception?(_), do: false

  defp get_owner_id(%{user_id: user_id}), do: user_id

  defp get_owner_id(%Placement{} = placement) do
    case placement.bookshelf do
      %{user_id: user_id} -> user_id
      _ -> nil
    end
  end

  defp get_owner_id(_), do: nil

  defp get_resource_visibility(%{visibility: visibility}), do: visibility

  defp get_resource_visibility(%{visibility_tier: _}), do: "public"

  defp get_resource_visibility(_), do: "owner"

  defp load_user(%{user_id: user_id}), do: Accounts.get_user(user_id)
  defp load_user(_), do: nil

  defp maybe_preload_bookshelf(%Placement{bookshelf: %Bookshelf{}} = placement), do: placement

  defp maybe_preload_bookshelf(%Placement{} = placement) do
    Repo.preload(placement, :bookshelf)
  end

  @doc """
  Returns true if the viewer can see the resource, false otherwise.
  """
  @spec can_view?(term(), term()) :: boolean()
  def can_view?(resource, viewer), do: resolve_visibility(resource, viewer) == :visible

  @doc """
  Whether a user's PROFILE (the hub page at `/u/:handle`) is visible to `viewer`.
  Visible when the viewer is the owner, OR the owner is not a ghost
  (`profile_visibility != "owner"`) and there is no block between them. Ghosts and
  blocked pairs → not visible (the controller renders 404, not 403). Distinct from
  `resolve_visibility/2`, which gates a RESOURCE — the hub itself is not a resource,
  so it needs an explicit gate that single-sources the profile-ceiling rule.
  """
  @spec profile_visible?(map(), term()) :: boolean()
  def profile_visible?(%{id: owner_id, profile_visibility: pv}, {:platform_user, viewer_id}) do
    cond do
      viewer_id == owner_id -> true
      pv == "owner" -> false
      Social.blocked?(viewer_id, owner_id) -> false
      pv in ["platform", "public"] -> true
      true -> false
    end
  end

  def profile_visible?(%{profile_visibility: pv}, :unauthenticated), do: pv == "public"
  def profile_visible?(_, _), do: false

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
  Batch-resolves placement visibility for placements sharing ONE viewer
  (the public shelf-browse surface). Block status and age-verification are
  per-(viewer, owner), so they're resolved once (one block query per
  distinct owner + one age lookup) — the shared-gate query count is
  independent of placement count. Each decision is identical to
  `resolve_visibility(placement, viewer)`; only lookups are memoized.
  Returns visible placements, input order preserved, unbounded (callers cap).
  """
  @spec filter_visible_placements([Placement.t()], term()) :: [Placement.t()]
  def filter_visible_placements(placements, viewer) when is_list(placements) do
    placements = Enum.map(placements, &maybe_preload_bookshelf/1)
    ctx = build_batch_context(placements, viewer)
    Enum.filter(placements, &(resolve_placement(&1, viewer, ctx) == :visible))
  end

  defp build_batch_context(placements, viewer) do
    viewer_id = batch_viewer_id(viewer)

    blocks =
      if is_nil(viewer_id) do
        %{}
      else
        placements
        |> Enum.map(&get_owner_id/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Map.new(fn owner_id -> {owner_id, Social.blocked?(viewer_id, owner_id)} end)
      end

    %{age_verified: viewer_age_verified?(viewer_id), blocks: blocks}
  end

  defp batch_viewer_id({:platform_user, viewer_id}), do: viewer_id
  defp batch_viewer_id(_viewer), do: nil

  @doc """
  Is `visibility` at least as exposed as `minimum` on the Audience ladder
  (`owner < group < platform < public`)? Use instead of equality checks —
  `Feeds` once tested `!= "platform"` and refused a feed to the MORE-shared
  `public` tier. Unknown visibility reads as exposure 0 (fails closed).

      iex> Stacks.Visibility.at_least?("public", "platform")
      true
      iex> Stacks.Visibility.at_least?("group", "platform")
      false
  """
  @spec at_least?(String.t(), String.t()) :: boolean()
  def at_least?(visibility, minimum) do
    Map.get(@audience_exposure, visibility, 0) >= Map.get(@audience_exposure, minimum, 0)
  end

  @doc """
  Validates that a child resource visibility is not MORE EXPOSED than its parent
  (the ceiling rule). On the Audience ladder
  `owner < group < platform < public` (exposure ascending), the child's exposure
  must be `<=` the parent's.

  Returns `:ok` if valid, or `{:error, reason}` if the child would expose
  more than the parent allows.
  """
  @spec validate_visibility_ceiling(String.t(), String.t(), atom()) ::
          :ok | {:error, String.t()}
  def validate_visibility_ceiling(child_visibility, parent_visibility, resource_type) do
    child_exposure = Map.get(@audience_exposure, child_visibility, 0)
    parent_exposure = Map.get(@audience_exposure, parent_visibility, 0)

    if child_exposure <= parent_exposure do
      :ok
    else
      {:error,
       "#{resource_type} visibility '#{child_visibility}' is less restrictive than parent visibility '#{parent_visibility}'"}
    end
  end

  @doc """
  The canonical stored Audience levels (`owner`, `group`, `platform`). Use this
  as the single source of truth for `validate_inclusion` on visibility fields
  rather than re-declaring the list per context (ADR-018 / #209).
  """
  @spec audience_levels() :: [String.t()]
  def audience_levels, do: @audience_levels

  @doc "Whether `value` is a valid stored Audience level."
  @spec valid_audience_level?(term()) :: boolean()
  def valid_audience_level?(value), do: value in @audience_levels

  @doc """
  The Audience levels settable on a user PROFILE (`owner`, `platform`). Narrower
  than `audience_levels/0` — `group` is reserved (a group profile is not yet
  enforced). Used by both registration and settings so the two agree.
  """
  @spec profile_audience_levels() :: [String.t()]
  def profile_audience_levels, do: @profile_audience_levels

  @doc """
  Classifies a visibility change by movement along the Audience ladder
  (`owner < group < platform < public`, exposure ascending). Uses the single
  `@audience_exposure` map — `"group"` sits between `owner` and `platform`, so a
  group→platform change is correctly a `:loosen` and platform→group a `:tighten`.

  - `:tighten` — the new value is LESS exposed (more restrictive)
  - `:loosen` — the new value is MORE exposed (less restrictive)
  - `:same` — no change in exposure
  """
  @spec classify_visibility_direction(String.t(), String.t()) :: :tighten | :loosen | :same
  def classify_visibility_direction(old_visibility, new_visibility) do
    old_exposure = Map.get(@audience_exposure, old_visibility, 0)
    new_exposure = Map.get(@audience_exposure, new_visibility, 0)

    cond do
      new_exposure < old_exposure -> :tighten
      new_exposure > old_exposure -> :loosen
      true -> :same
    end
  end

  @doc """
  Emits the `[:stacks, :visibility, :profile_change]` counter, tagged by the
  change `:direction` (`:tighten` / `:loosen` / `:same`). Returns the direction.
  """
  @spec emit_profile_visibility_change(String.t(), String.t()) :: :tighten | :loosen | :same
  def emit_profile_visibility_change(old_visibility, new_visibility) do
    direction = classify_visibility_direction(old_visibility, new_visibility)

    :telemetry.execute(
      [:stacks, :visibility, :profile_change],
      %{count: 1},
      %{direction: direction}
    )

    direction
  end

  @doc """
  Emits the `[:stacks, :visibility, :ceiling_rejection]` counter when a
  mutation is rejected for exceeding its parent's visibility ceiling. The
  `resource_type` tag is whitelisted (`:bookshelf` / `:placement` / `:post`);
  any other value is coerced to `:other`.

  Call this from the genuine user-facing rejection sites (shelf/placement/blog
  mutation error branches) — NOT from the batch-tighten filter path, which
  expects and caps violations rather than rejecting them.
  """
  @spec emit_ceiling_rejection(atom()) :: :ok
  def emit_ceiling_rejection(resource_type) do
    tag = if resource_type in @ceiling_resource_types, do: resource_type, else: :other

    :telemetry.execute(
      [:stacks, :visibility, :ceiling_rejection],
      %{count: 1},
      %{resource_type: tag}
    )
  end
end
