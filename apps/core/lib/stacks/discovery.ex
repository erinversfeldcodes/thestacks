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

  @doc """
      Creates a new discovered source with `status: "pending_review"` and
      `discovered_at` set to the current timestamp.

      Returns `{:error,:duplicate}` if a source with the same URL already exists.
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

  defp after_transition({:ok, updated} = result, target_status, event_type) do
    Events.emit_safe(%{
      event_type: event_type,
      aggregate_type: "discovered_source",
      aggregate_id: updated.id,
      payload: %{status: to_string(target_status)}
    })

    if target_status == "approved", do: create_third_space(updated)

    result
  end

  defp after_transition(error, _target_status, _event_type), do: error

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

  @space_like_types ~w(community event_source)

  @type_for_source %{"community" => "community_centre", "event_source" => "cafe"}

  @doc """
      Creates the `third_space` for a newly approved source — deliberately
      the ONLY producer of `op.third_spaces`: these are real businesses with
      real reputations, so a human approval is the gate; no discovery job
      writes the table. (The documented `DiscoverThirdSpacesJob` never
      existed — hence the table's historical zero rows.) Geocoding happens
      here at approval (human-paced, honouring Nominatim's ~1 req/s) and the
      nearest-bookshop distance is stored once, so the 500m filter is a scalar
      comparison at render time.
  """
  @spec create_third_space(DiscoveredSource.t()) :: :ok
  def create_third_space(%DiscoveredSource{type: type} = source)
      when type in @space_like_types do
    if space_exists?(source.url) do
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

  defp source_city(source), do: Map.get(source, :city)

  @doc """
      Opts a source out by URL. Sets `status: "excluded"`, `excluded_at`, and
      `exclusion_email`. The URL must match an existing discovered source.

      Returns `{:error,:not_found}` if no source matches the URL.
      Returns `{:ok,:excluded, source}` when the requester's email domain matches the
      listing's, so the removal was applied; `{:ok,:pending_review, source}` when it did not,
      so the request was recorded for owner review and **the listing is still live**.

      Returns `{:error,:not_found}` if no source matches the URL, or
      `{:error,:invalid_email}` if the email format is invalid.
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

  defp delist_third_space(url) do
    now = DateTime.utc_now()

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

      %URI{path: path} when is_binary(path) and path != "" ->
        path |> String.split("/") |> List.first()

      _ ->
        nil
    end
  end

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
    Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email)
  end
end
