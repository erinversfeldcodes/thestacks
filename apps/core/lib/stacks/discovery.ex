defmodule Stacks.Discovery do
  @moduledoc """
  Context for managing discovered sources — bookshops, review sites,
  community spaces, and event sources found via automated search.

  Handles CRUD, deduplication by URL, status transitions, and the
  unauthenticated business opt-out flow.
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Enrichment
  alias Stacks.Enrichment.Bookstore
  alias Stacks.Enrichment.DiscoveredSource
  alias Stacks.Enrichment.ThirdSpace
  alias Stacks.Events
  alias Stacks.Geocoding

  require Logger

  import Stacks.Enrichment, only: [third_space_changeset: 2]

  # ---------------------------------------------------------------------------
  # Create
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new discovered source with `status: "pending_review"` and
  `discovered_at` set to the current timestamp.

  Returns `{:error, :duplicate}` if a source with the same URL already exists.
  """
  @spec create_source(map()) :: {:ok, DiscoveredSource.t()} | {:error, term()}
  def create_source(attrs) do
    url = Map.get(attrs, :url) || Map.get(attrs, "url")

    if url && get_source_by_url(url) do
      {:error, :duplicate}
    else
      now = DateTime.utc_now()

      attrs =
        attrs
        |> Map.put_new(:status, "pending_review")
        |> Map.put_new(:discovered_at, now)

      %DiscoveredSource{}
      |> Enrichment.discovered_source_changeset(attrs)
      |> Repo.insert()
    end
  end

  # ---------------------------------------------------------------------------
  # Read
  # ---------------------------------------------------------------------------

  @doc "Fetches a discovered source by its URL, or nil if not found."
  @spec get_source_by_url(String.t()) :: DiscoveredSource.t() | nil
  def get_source_by_url(url) when is_binary(url) do
    Repo.one(from(s in DiscoveredSource, where: s.url == ^url))
  end

  @doc "Fetches a discovered source by its ID, or nil if not found."
  @spec get_source(String.t()) :: DiscoveredSource.t() | nil
  def get_source(id) when is_binary(id) do
    Repo.get(DiscoveredSource, id)
  end

  @doc "Returns all sources with `status: \"pending_review\"`."
  @spec pending_sources() :: [DiscoveredSource.t()]
  def pending_sources do
    Repo.all(from(s in DiscoveredSource, where: s.status == "pending_review"))
  end

  @doc """
  Returns approved sources matching the given city and/or country code.

  Searches the `discovered_via` field for location context. Both parameters
  are optional — if both are nil, returns all approved sources.
  """
  @spec sources_for_location(String.t() | nil, String.t() | nil) :: [DiscoveredSource.t()]
  def sources_for_location(city, country_code) do
    query = from(s in DiscoveredSource, where: s.status == "approved")

    query =
      if city do
        escaped = escape_like(city)
        from(s in query, where: ilike(s.discovered_via, ^"%#{escaped}%"))
      else
        query
      end

    query =
      if country_code do
        escaped = escape_like(country_code)
        from(s in query, where: ilike(s.discovered_via, ^"%#{escaped}%"))
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Lists discovered sources with optional filtering and pagination.

  Options:
  - `:status` — filter by status atom or string (e.g. `:pending_review`, `"approved"`)
  - `:type` — filter by source type atom or string (e.g. `:bookshop`, `"review_site"`)
  - `:page` — page number (default 1)
  - `:per_page` — results per page (default 50)

  Returns `{sources, total_count}`.
  """
  @spec list_sources(keyword()) :: {[DiscoveredSource.t()], non_neg_integer()}
  def list_sources(opts \\ []) do
    page = parse_int(opts[:page], 1)
    per_page = min(parse_int(opts[:per_page], 50), 200)

    query = from(s in DiscoveredSource, order_by: [desc: s.created_at])

    query = maybe_filter_status(query, opts[:status])
    query = maybe_filter_type(query, opts[:type])

    total = Repo.aggregate(query, :count, :id)

    sources =
      query
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    {sources, total}
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status) when is_atom(status) do
    maybe_filter_status(query, to_string(status))
  end

  defp maybe_filter_status(query, status) when is_binary(status) do
    from(s in query, where: s.status == ^status)
  end

  defp maybe_filter_type(query, nil), do: query

  defp maybe_filter_type(query, type) when is_atom(type) do
    maybe_filter_type(query, to_string(type))
  end

  defp maybe_filter_type(query, type) when is_binary(type) do
    from(s in query, where: s.type == ^type)
  end

  defp parse_int(nil, default), do: default
  defp parse_int(val, _default) when is_integer(val), do: max(val, 1)

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> max(n, 1)
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # ---------------------------------------------------------------------------
  # Update
  # ---------------------------------------------------------------------------

  @doc """
  Updates the status of a discovered source. Accepts a status string and
  optional additional attributes (e.g., `approved_at` for approvals).
  """
  @spec update_source_status(DiscoveredSource.t(), map()) ::
          {:ok, DiscoveredSource.t()} | {:error, Ecto.Changeset.t()}
  def update_source_status(%DiscoveredSource{} = source, attrs) do
    source
    |> Enrichment.discovered_source_status_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates the confidence score for a discovered source.
  """
  @spec update_confidence(DiscoveredSource.t(), float()) ::
          {:ok, DiscoveredSource.t()} | {:error, Ecto.Changeset.t()}
  def update_confidence(%DiscoveredSource{} = source, confidence)
      when is_float(confidence) do
    source
    |> Enrichment.discovered_source_confidence_changeset(%{confidence: confidence})
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Admin transitions
  # ---------------------------------------------------------------------------

  @doc """
  Approves a discovered source. Only sources with `status: "pending_review"`
  can be approved. Sets `approved_at` to the current timestamp.

  Emits a `source.approved` event on success.
  """
  @spec approve_source(String.t()) ::
          {:ok, DiscoveredSource.t()} | {:error, :not_found | :invalid_transition}
  def approve_source(source_id) when is_binary(source_id) do
    transition_source(source_id, "approved", "source.approved")
  end

  @doc """
  Rejects a discovered source. Only sources with `status: "pending_review"`
  can be rejected. Transitions status to `:dismissed`.

  Emits a `source.rejected` event on success.
  """
  @spec reject_source(String.t()) ::
          {:ok, DiscoveredSource.t()} | {:error, :not_found | :invalid_transition}
  def reject_source(source_id) when is_binary(source_id) do
    transition_source(source_id, "dismissed", "source.rejected")
  end

  defp transition_source(source_id, target_status, event_type) do
    case get_source(source_id) do
      nil ->
        {:error, :not_found}

      %DiscoveredSource{status: "pending_review"} = source ->
        attrs = %{status: target_status}

        attrs =
          if target_status == "approved" do
            Map.put(attrs, :approved_at, DateTime.utc_now())
          else
            attrs
          end

        source
        |> update_source_status(attrs)
        |> after_transition(target_status, event_type)

      %DiscoveredSource{} ->
        {:error, :invalid_transition}
    end
  end

  # The side effects of a successful transition, extracted so `transition_source/3` stays
  # flat. Pattern-matching the two outcomes in function heads also means the failure path
  # cannot accidentally fall through the success path's effects.
  defp after_transition({:ok, updated} = result, target_status, event_type) do
    Events.emit_safe(%{
      event_type: event_type,
      aggregate_type: "discovered_source",
      aggregate_id: updated.id,
      payload: %{status: to_string(target_status)}
    })

    # Approval is the only producer of `op.third_spaces` — see `create_third_space/1`.
    if target_status == "approved", do: create_third_space(updated)

    result
  end

  defp after_transition(error, _target_status, _event_type), do: error

  # ---------------------------------------------------------------------------
  # Removal-request review queue (US-2.5.3)
  # ---------------------------------------------------------------------------

  @doc """
  Removal requests waiting for a human decision.

  A request whose contact address did not match the listing's domain sets
  `exclusion_requested_at` and leaves `status` alone — that pair *is* the pending state, so
  no enum value had to be invented for it. This is the query that makes it visible.

  ⚠️ **Without this the parked requests were invisible.** The admin payload did not carry
  `exclusion_requested_at` at all, so a business whose request could not be auto-verified
  waited on a human who had no way to know they were waiting. A queue nobody can see is
  indistinguishable from a request that was silently refused.

  Oldest first: these are people waiting, and the fair order is the order they asked in.
  """
  @spec pending_removal_requests() :: [DiscoveredSource.t()]
  def pending_removal_requests do
    Repo.all(
      from s in DiscoveredSource,
        where: not is_nil(s.exclusion_requested_at) and s.status != "excluded",
        order_by: [asc: s.exclusion_requested_at]
    )
  end

  @doc """
  Honour a removal request: exclude the source and delist the third space.

  ⚠️ **Named `honour_removal_request` and not `approve` on purpose.**
  `approve_source/1` already exists and means *approve the listing* — the opposite effect.
  Two functions called "approve" doing opposite things to the same row is precisely the
  mistake that gets made at 2am, so these say what happens to the *listing* instead:
  honour (it goes) or decline (it stays).

  Reuses the same effect as a domain-verified request, so a listing removed by hand and one
  removed automatically end in the same state — there is one notion of "removed".
  """
  @spec honour_removal_request(String.t()) ::
          {:ok, DiscoveredSource.t()} | {:error, :not_found | :not_pending | term()}
  def honour_removal_request(source_id) when is_binary(source_id) do
    with {:ok, source} <- fetch_pending_removal(source_id) do
      update_source_status(source, %{
        status: "excluded",
        excluded_at: DateTime.utc_now()
      })
      |> case do
        {:ok, updated} ->
          delist_third_space(updated.url)
          {:ok, updated}

        other ->
          other
      end
    end
  end

  @doc """
  Decline a removal request: the listing stays.

  Clears `exclusion_requested_at` so the request leaves the queue, and deliberately keeps
  `exclusion_email` — a declined request is a record worth having if the same business asks
  again, and losing it would make a repeat look like a first contact.
  """
  @spec decline_removal_request(String.t()) ::
          {:ok, DiscoveredSource.t()} | {:error, :not_found | :not_pending | term()}
  def decline_removal_request(source_id) when is_binary(source_id) do
    with {:ok, source} <- fetch_pending_removal(source_id) do
      update_source_status(source, %{
        status: source.status,
        exclusion_requested_at: nil
      })
    end
  end

  # Refuses anything that is not actually pending, so a double-click cannot re-run a
  # decision and an already-excluded source cannot be "declined" back into visibility.
  defp fetch_pending_removal(source_id) do
    case get_source(source_id) do
      nil ->
        {:error, :not_found}

      %DiscoveredSource{exclusion_requested_at: nil} ->
        {:error, :not_pending}

      %DiscoveredSource{status: "excluded"} ->
        {:error, :not_pending}

      source ->
        {:ok, source}
    end
  end

  # ---------------------------------------------------------------------------
  # Third-space production (US-3.1.1)
  # ---------------------------------------------------------------------------

  # Source types that describe a place a reader could sit in. `bookshop` is excluded on
  # purpose: bookshops live in `op.bookstores` and are the *other* side of the 500 m
  # pairing, so making one a third space too would let a shop satisfy the rule by being
  # near itself.
  @space_like_types ~w(community event_source)

  # Maps a discovered-source type onto the `op.space_type` enum. Coarse by necessity —
  # discovery knows "community", not "garden" — so an owner refines it afterwards. Being
  # honest about coarseness beats guessing a specific category from a URL.
  @type_for_source %{"community" => "community_centre", "event_source" => "cafe"}

  @doc """
  Creates the `third_space` for a newly approved source.

  ⚠️ **This is the only producer of `op.third_spaces`, deliberately.** These are real
  businesses with real reputations, and listing one that no human has looked at is
  precisely the harm US-2.5.3 exists to remedy — so approval is the gate, and there is no
  discovery job that writes the table directly.

  It also fixes a documentation lie: `implementation-mapping.md:2115` listed a
  `DiscoverThirdSpacesJob` as "Scheduled (weekly)". No such module has ever existed,
  which is why the table sat at zero rows while the docs asserted a running pipeline.

  Geocoding happens **here, at approval**, not at render time:

    * it is human-paced, so Nominatim's ~1 req/sec policy is honoured structurally;
    * the nearest-bookshop distance is computed once and stored, so the 500 m filter is
      a scalar comparison rather than a per-pan recomputation across the viewport.

  A space that cannot be geocoded is still created, with null coordinates. That is a
  real state and must stay visible to the owner: silently discarding it would lose an
  approval the owner explicitly made, and `list_third_spaces/1` already excludes
  unpositioned spaces from geo queries, so it cannot leak onto the map as if positioned.

  Returns `:ok` regardless. A failure here must not roll back an approval the owner
  performed — the source is approved either way, and a missing space can be retried.
  """
  @spec create_third_space(DiscoveredSource.t()) :: :ok
  def create_third_space(%DiscoveredSource{type: type} = source)
      when type in @space_like_types do
    if space_exists?(source.url) do
      # Approval is idempotent from the owner's side, so re-approving must not create a
      # second listing for the same business.
      :ok
    else
      insert_third_space(source)
    end
  end

  def create_third_space(_source), do: :ok

  defp insert_third_space(source) do
    city = source_city(source)

    attrs = %{
      name: source.name,
      type: Map.get(@type_for_source, source.type, "cafe"),
      city: city,
      website_url: source.url,
      discovered_via: source.discovered_via || "source_approval",
      verified: false
    }

    attrs = Map.merge(attrs, position_for(attrs))

    %ThirdSpace{}
    |> third_space_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, space} ->
        Events.emit_safe(%{
          event_type: "third_space.created",
          aggregate_type: "third_space",
          aggregate_id: space.id,
          payload: %{source_id: source.id, geocoded: not is_nil(space.latitude)}
        })

        :ok

      {:error, changeset} ->
        Logger.warning(
          "Discovery: could not create third space for #{source.url}: #{inspect(changeset.errors)}"
        )

        :ok
    end
  end

  # Geocode, then pair with the nearest bookshop. Returns an empty map when geocoding
  # fails, so the space is created unpositioned rather than not created.
  defp position_for(attrs) do
    case Geocoding.geocode(Geocoding.query_for(attrs)) do
      {:ok, %{latitude: lat, longitude: lng}} ->
        %{
          latitude: lat,
          longitude: lng,
          nearest_bookshop_km: nearest_bookshop_km(lat, lng)
        }

      {:error, reason} ->
        Logger.info(
          "Discovery: could not geocode #{inspect(attrs[:name])} (#{inspect(reason)}); " <>
            "creating the space unpositioned so the approval is not lost"
        )

        %{}
    end
  end

  # Distance to the closest bookshop that has coordinates, or nil when none do.
  #
  # nil is meaningfully different from a large number: it means "not computed", and
  # `list_third_spaces/1` refuses to treat it as "near", so a space cannot reach the map
  # on the strength of missing data.
  defp nearest_bookshop_km(lat, lng) do
    Repo.all(
      from b in Bookstore,
        where: not is_nil(b.latitude) and not is_nil(b.longitude),
        select: {b.latitude, b.longitude}
    )
    |> Enum.map(fn {blat, blng} -> Enrichment.haversine_km(lat, lng, blat, blng) end)
    |> case do
      [] -> nil
      distances -> Enum.min(distances)
    end
  end

  defp space_exists?(url) do
    Repo.exists?(from s in ThirdSpace, where: s.website_url == ^url)
  end

  # Discovery does not capture a city, so it is inferred from the source's own record
  # where present. Left nil rather than guessed when absent — a wrong city makes the
  # geocoding query worse, not better.
  defp source_city(source), do: Map.get(source, :city)

  # ---------------------------------------------------------------------------
  # Opt-out
  # ---------------------------------------------------------------------------

  @doc """
  Opts a source out by URL. Sets `status: "excluded"`, `excluded_at`, and
  `exclusion_email`. The URL must match an existing discovered source.

  Returns `{:error, :not_found}` if no source matches the URL.
  Returns `{:ok, :excluded, source}` when the requester's email domain matches the
  listing's, so the removal was applied; `{:ok, :pending_review, source}` when it did not,
  so the request was recorded for owner review and **the listing is still live**.

  Returns `{:error, :not_found}` if no source matches the URL, or
  `{:error, :invalid_email}` if the email format is invalid.
  """
  @spec opt_out(String.t(), map()) ::
          {:ok, :excluded | :pending_review, DiscoveredSource.t()}
          | {:error, :not_found | :invalid_email | Ecto.Changeset.t()}
  def opt_out(url, %{email: email} = _params) when is_binary(url) and is_binary(email) do
    if valid_email?(email) do
      case get_source_by_url(url) do
        nil -> {:error, :not_found}
        source -> record_removal_request(source, email)
      end
    else
      {:error, :invalid_email}
    end
  end

  # Applies the removal when the requester demonstrably belongs to the business;
  # otherwise records it for owner review.
  #
  # This used to exclude on submission unconditionally, which meant **anyone who knew a
  # listing's URL could delist any business.** The form deliberately has no account
  # behind it (US-2.5.3: "does not require account creation"), so submission alone
  # cannot be evidence of ownership.
  #
  # The test is whether the contact email's domain matches the listing's own domain.
  # That is not proof of ownership, but it is the same standard most services use for
  # business verification, it needs no human in the loop, and it is correct for the
  # common case — a shop at `booklounge.co.za` writing from `…@booklounge.co.za`.
  # Anything else (a Gmail address, an agency, a personal account) is plausible but
  # unverifiable here, so it waits for a human rather than being trusted or refused.
  defp record_removal_request(source, email) do
    if email_domain_matches_source?(email, source.url) do
      update_source_status(source, %{
        status: "excluded",
        excluded_at: DateTime.utc_now(),
        exclusion_requested_at: DateTime.utc_now(),
        exclusion_email: email
      })
      |> case do
        {:ok, updated} ->
          # ⚠️ The source is how we *found* the business; the `third_space` is what a
          # reader actually sees. Excluding only the source would leave the listing on the
          # map — the exact outcome the request asked us to prevent.
          delist_third_space(updated.url)
          {:ok, :excluded, updated}

        other ->
          other
      end
    else
      # Status is deliberately untouched: the listing stays live until a human agrees.
      # `exclusion_requested_at` set while status is not `excluded` *is* the pending
      # state, so the request is visible without inventing an enum value.
      update_source_status(source, %{
        exclusion_requested_at: DateTime.utc_now(),
        exclusion_email: email
      })
      |> case do
        {:ok, updated} -> {:ok, :pending_review, updated}
        other -> other
      end
    end
  end

  # Soft-deletes the third space for a delisted business.
  #
  # ⚠️ **Never a hard delete, and this is the load-bearing reason:** the discovery
  # pipeline re-finds sources continuously, so a deleted row would be rediscovered,
  # re-approved by an owner with no record of the objection, and re-listed — turning one
  # removal request into a recurring one. The surviving row with `opted_out: true` is what
  # makes the removal *stick*: `Discovery.create_third_space/1` refuses to create a second
  # listing for a URL it already holds, and `Enrichment.list_third_spaces/1` excludes
  # opted-out spaces from every query.
  #
  # Matched by `website_url` because that is what the space carries from its source, and
  # it is the same value the requester submitted.
  #
  # Returns `:ok` regardless — a business asked to be delisted, and a bookkeeping failure
  # here must not turn that into an error the requester sees. It is logged loudly instead,
  # because a space that stayed listed after a verified request is a real problem.
  defp delist_third_space(url) do
    now = DateTime.utc_now()

    # Ids first, then update by id. `update_all`'s `:returning` is driver-dependent and
    # came back nil here, and a removal request is rare enough that two queries cost
    # nothing — whereas relying on a capability that silently returns nil cost a debugging
    # cycle.
    ids =
      Repo.all(
        from s in ThirdSpace,
          where: s.website_url == ^url and s.opted_out == false,
          select: s.id
      )

    {count, _} =
      Repo.update_all(
        from(s in ThirdSpace, where: s.id in ^ids),
        set: [opted_out: true, opted_out_at: now, updated_at: now]
      )

    if count > 0 do
      Logger.info("Discovery: delisted #{count} third space(s) for #{url}")

      # One event per space, keyed by the space's id.
      #
      # ⚠️ Deliberately carries **no URL and no payload**. The first draft emitted a single
      # event with `aggregate_id: url` and `payload: %{url: url}`, and the PII lint refused
      # it — correctly. `event_log` is immutable and only GDPR-erasable for PII, so a
      # free-text value in it is permanent; and a third space IS the aggregate here, so the
      # id is both more accurate and carries nothing that needs justifying.
      Enum.each(ids, fn id ->
        Events.emit_safe(%{
          event_type: "third_space.delisted",
          aggregate_type: "third_space",
          aggregate_id: id,
          payload: %{}
        })
      end)
    end

    :ok
  end

  @doc """
  Whether `email`'s domain matches the domain of `url`.

  Compares registrable domains rather than exact hosts, so `hello@booklounge.co.za`
  matches `https://www.booklounge.co.za/about` — a `www.` prefix or a deep path must not
  defeat a legitimate request. Multi-part public suffixes (`.co.za`, `.com.au`) are why
  this compares the last **three** labels when the second-to-last is a known
  second-level suffix, rather than naively taking the last two.
  """
  @spec email_domain_matches_source?(String.t(), String.t() | nil) :: boolean()
  def email_domain_matches_source?(email, url) do
    with [_local, email_host] <- String.split(email, "@", parts: 2),
         host when is_binary(host) <- url_host(url) do
      registrable(email_host) == registrable(host) and registrable(host) != ""
    else
      _ -> false
    end
  end

  defp url_host(nil), do: nil

  defp url_host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        host

      # A bare domain with no scheme parses with a nil host and the whole string as path.
      %URI{path: path} when is_binary(path) and path != "" ->
        path |> String.split("/") |> List.first()

      _ ->
        nil
    end
  end

  # Second-level suffixes we actually encounter. Not a full public-suffix list — that is
  # a dependency and a data-update burden — but enough for the ZA-first target list, and
  # a mismatch only ever routes a request to human review rather than refusing it.
  @second_level_suffixes ~w(co ac org net gov edu com)

  defp registrable(host) do
    labels =
      host
      |> String.downcase()
      |> String.trim_trailing(".")
      |> String.split(".")
      |> Enum.reject(&(&1 == ""))

    case Enum.reverse(labels) do
      [tld, second, third | _] when second in @second_level_suffixes ->
        Enum.join([third, second, tld], ".")

      [tld, second | _] ->
        Enum.join([second, tld], ".")

      _ ->
        ""
    end
  end

  defp valid_email?(email) do
    # Simple email format validation
    Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email)
  end
end
