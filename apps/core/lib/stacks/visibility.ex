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

  # The stored, user-settable Audience levels (owner < group < platform < public).
  # `public` = "anyone with the link, signed in or not" (#225); still `noindex`.
  # Single source of truth for the per-context validate_inclusion lists (Shelving /
  # Blog / Accounts), replacing their duplicated `~w(...)`.
  @audience_levels ~w(owner group platform public)

  # Audience levels settable on a USER PROFILE — owner / platform / public. `group`
  # ("friends-only") profiles are deferred to #224 (need a chosen-group FK), so the
  # rung is not offered here yet. Used by BOTH profile registration and
  # settings-update, keeping them consistent.
  @profile_audience_levels ~w(owner platform public)

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

  # ---------------------------------------------------------------------------
  # Internal resolution logic
  # ---------------------------------------------------------------------------

  # Placement dispatch shared by the single-resolve public clauses and the batch
  # entrypoint (`filter_visible_placements/2`). `ctx` is `nil` for a one-off
  # resolve (the shared block/age gates hit the DB live) or a batch context (the
  # shared gates are memoized once per request). The DECISION is identical either
  # way — `ctx` only changes WHERE the shared-gate answers come from, never what
  # they are.
  defp resolve_placement(%Placement{} = placement, {:platform_user, viewer_id} = viewer, ctx) do
    if marketplace_exception?(placement) do
      # Marketplace listings are broadly discoverable, but a block still hides
      # ALL of the owner's content (SEC-2): honour the bidirectional block even
      # for an active listing, before granting the marketplace exception.
      case check_block(get_owner_id(placement), viewer_id, ctx) do
        :ok -> :visible
        :hidden -> :hidden
      end
    else
      do_resolve(placement, viewer, viewer_id, ctx)
    end
  end

  defp resolve_placement(%Placement{} = placement, :platform_preview, ctx) do
    # A platform-preview has no viewer identity (never the owner, in no groups,
    # no block relationship), so an active listing is simply visible.
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
      # An owner profile hides all content from non-owners.
      {"owner", _} -> :hidden
      # A "platform" (Members) profile is signed-in-only: it caps everything away
      # from logged-out visitors, so a `public` shelf under a Members profile is
      # NOT leaked to anon (the profile is the ceiling). (#225)
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
      # Owner preloaded (bookshelf: :user) — reuse it, no per-placement query.
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

  # ---------------------------------------------------------------------------
  # Block check (bidirectional)
  # ---------------------------------------------------------------------------

  defp check_block(_owner_id, nil, _ctx), do: :ok
  defp check_block(nil, _viewer_id, _ctx), do: :ok

  defp check_block(owner_id, viewer_id, ctx) do
    if blocked_pair?(owner_id, viewer_id, ctx) do
      :hidden
    else
      :ok
    end
  end

  # The (viewer, owner) block status is identical for every resource of one owner
  # viewed by one viewer, so the batch context memoizes it per owner_id (one query
  # per distinct owner, not per placement). A nil context resolves live —
  # unchanged single-resolve behaviour.
  defp blocked_pair?(owner_id, viewer_id, nil), do: Social.blocked?(viewer_id, owner_id)

  defp blocked_pair?(owner_id, viewer_id, %{blocks: blocks}) do
    case Map.fetch(blocks, owner_id) do
      {:ok, blocked?} -> blocked?
      :error -> Social.blocked?(viewer_id, owner_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Age gate check
  # ---------------------------------------------------------------------------

  # A PLACEMENT inherits its BOOK's age gate (#213): the placement itself has no
  # `visibility_tier`, so an age-gated book on a shelf must be gated via its book.
  # An age-gated placement is HIDDEN from a viewer who is neither the owner nor
  # age-verified — so it never reaches the frontend to render (the visible books
  # simply pack together, no gaps). The owner always sees their own shelf.
  defp check_age_gate(%Placement{} = placement, viewer_id, ctx) do
    placement = maybe_preload_book(placement)

    cond do
      # Shipped dark (ADR-020): flag off → age-gating is inert, gate is :ok.
      not Stacks.FeatureFlags.age_gating_enabled?() -> :ok
      not age_gated_book?(placement.book) -> :ok
      not is_nil(viewer_id) and get_owner_id(placement) == viewer_id -> :ok
      viewer_age_verified?(viewer_id, ctx) -> :ok
      true -> :hidden
    end
  end

  defp check_age_gate(%{visibility_tier: "age_gated"}, viewer_id, ctx) do
    # Shipped dark (ADR-020): flag off → age-gating is inert, gate is :ok.
    cond do
      not Stacks.FeatureFlags.age_gating_enabled?() -> :ok
      viewer_age_verified?(viewer_id, ctx) -> :ok
      true -> :hidden
    end
  end

  defp check_age_gate(_resource, _viewer_id, _ctx), do: :ok

  # The viewer is constant across a batch, so its age-verification is resolved
  # ONCE into the context; a nil context resolves live (unchanged single path).
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
      # public = anyone with the link, signed in or not (#225).
      {"public", _} ->
        :ok

      # platform = "Members" = any SIGNED-IN user; hidden from logged-out visitors.
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

  # "platform" (Members) is visible to any authenticated viewer (incl. the
  # identity-less platform-preview) but NOT to a logged-out visitor. (#225)
  defp check_platform_audience({:platform_user, _}), do: :ok
  defp check_platform_audience(:platform_preview), do: :ok
  defp check_platform_audience(_), do: :hidden

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
      # A signed-in viewer sees "Members" (platform) and public profiles. (group
      # profiles are #224; not a settable value yet.)
      pv in ["platform", "public"] -> true
      true -> false
    end
  end

  # A logged-out visitor sees ONLY public profiles — "Members" (platform) is
  # signed-in-only, owner is private. (#225)
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
  Batch-resolves placement visibility for a list of placements that share ONE
  viewer — the public shelf-browse surface (`/u/:handle/bookshelves/:name`).

  The (viewer, owner) block status and the viewer's age-verification are
  identical for every placement of a given owner, so they are resolved ONCE here
  (one block query per DISTINCT owner + one age-verification lookup for the
  viewer) instead of once per placement. The per-request shared-gate query count
  is therefore independent of the placement count. Each placement's decision is
  identical to `resolve_visibility(placement, viewer)` — only the shared-gate
  lookups are memoized, never the decision. Returns the visible placements,
  input order preserved.

  Callers that also need to BOUND the result (e.g. the public browse) should cap
  the returned list; this function does not itself limit, so it stays reusable
  for the owner's own full-shelf view.
  """
  @spec filter_visible_placements([Placement.t()], term()) :: [Placement.t()]
  def filter_visible_placements(placements, viewer) when is_list(placements) do
    placements = Enum.map(placements, &maybe_preload_bookshelf/1)
    ctx = build_batch_context(placements, viewer)
    Enum.filter(placements, &(resolve_placement(&1, viewer, ctx) == :visible))
  end

  # Precomputes the request-scoped shared gates: the viewer's age-verification
  # (one lookup) and the (viewer, owner) block status per DISTINCT owner (one
  # query each). Unauthenticated viewers can neither be blocked nor age-verified,
  # so both collapse to the empty/false case with no queries.
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
