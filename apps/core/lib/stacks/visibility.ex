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

  # Canonical Audience ladder, ordered by EXPOSURE (ascending = more exposed):
  #   owner (only self) < group (group members) < platform (any authed user)
  #   < public (anyone, incl. unauthenticated).
  # This single map (ADR-018 / #209 Phase 2) replaces the former TWO maps — the
  # ceiling map (which omitted "group", defaulting it to 0 and thereby WRONGLY
  # rejecting a group child under a platform/owner parent) and the profile
  # change-direction map. It now drives BOTH the ceiling check and the
  # tighten/loosen classification. Unknown values default to 0 (owner / least
  # exposed) — fail-safe: an unrecognised value is never treated as over-exposed.
  @audience_exposure %{"owner" => 0, "group" => 1, "platform" => 2, "public" => 3}

  # The stored, user-settable Audience levels (owner < group < platform). The
  # "public" rung is RESERVED (ADR-018) and not yet a stored value, so it is not
  # offered here. Single source of truth for the per-context validate_inclusion
  # lists (Shelving / Blog / Accounts), replacing their duplicated `~w(...)`.
  @audience_levels ~w(owner group platform)

  # Audience levels settable on a USER PROFILE — narrower than @audience_levels:
  # a "group" profile ceiling is not yet enforced (a group profile currently
  # behaves like platform), so it is RESERVED and not offered (ADR-018 per-entity
  # matrix). Used by BOTH profile registration and settings-update, resolving the
  # prior inconsistency where registration accepted "group" but settings did not.
  @profile_audience_levels ~w(owner platform)

  # Whitelist of resource-type tags for the ceiling-rejection counter. Anything
  # else is coerced to :other so telemetry cardinality stays bounded and no raw
  # caller-supplied value leaks into a metric label.
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

  def resolve_visibility(%Placement{} = placement, {:platform_user, viewer_id} = viewer) do
    placement = maybe_preload_bookshelf(placement)

    if marketplace_exception?(placement) do
      # Marketplace listings are broadly discoverable, but a block still hides
      # ALL of the owner's content (SEC-2): honour the bidirectional block even
      # for an active listing, before granting the marketplace exception.
      check_block(get_owner_id(placement), viewer_id)
      |> case do
        :ok -> :visible
        :hidden -> :hidden
      end
    else
      do_resolve(placement, viewer, viewer_id)
    end
  end

  def resolve_visibility(%Placement{} = placement, :platform_preview) do
    placement = maybe_preload_bookshelf(placement)
    # A platform-preview has no viewer identity (never the owner, in no groups,
    # no block relationship), so an active listing is simply visible.
    if marketplace_exception?(placement),
      do: :visible,
      else: do_resolve(placement, :platform_preview, nil)
  end

  def resolve_visibility(%Placement{} = placement, :unauthenticated) do
    placement = maybe_preload_bookshelf(placement)
    do_resolve(placement, :unauthenticated, nil)
  end

  def resolve_visibility(resource, {:platform_user, viewer_id} = viewer) do
    do_resolve(resource, viewer, viewer_id)
  end

  def resolve_visibility(resource, :platform_preview) do
    do_resolve(resource, :platform_preview, nil)
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

  defp check_default_visibility(owner_id, viewer_id) when owner_id == viewer_id, do: :ok
  defp check_default_visibility(_owner_id, _viewer_id), do: :hidden

  # Group visibility: membership in the shelf's target group is the access grant.
  # The visibility_group_id on the bookshelf identifies which group has access.
  # visibility_grants is reserved for "specific people" grants (future tier).
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
      true -> true
    end
  end

  def profile_visible?(%{profile_visibility: pv}, :unauthenticated), do: pv != "owner"
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

  # ---------------------------------------------------------------------------
  # Telemetry (Issue #197 — visibility/privacy observability)
  #
  # All metadata tags are whitelisted atoms — never raw user input — so metric
  # label cardinality stays bounded.
  # ---------------------------------------------------------------------------

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
