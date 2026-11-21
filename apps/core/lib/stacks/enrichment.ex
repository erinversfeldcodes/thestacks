defmodule Stacks.Enrichment do
  @moduledoc """
      Unified context for enrichment changeset functions.

      Changeset logic lives here rather than in the schema modules so that
      schemas can be replaced by auto-generated code while validation rules
      remain hand-written and testable.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Core.Repo
  alias Stacks.Books.BookEdition
  alias Stacks.Enrichment.BookstoreEvent
  alias Stacks.Enrichment.DiscoveredSource
  alias Stacks.Enrichment.PriceSnapshot
  alias Stacks.Enrichment.ReviewSnapshot
  alias Stacks.Enrichment.ThirdSpace
  alias Stacks.Enrichment.ThirdSpaceEvent
  alias Stacks.Partners.{InventoryItem, Partner}

  @doc "Changeset for creating a new discovered source."
  @spec discovered_source_changeset(DiscoveredSource.t(), map()) :: Ecto.Changeset.t()
  def discovered_source_changeset(%DiscoveredSource{} = source, attrs) do
    source
    |> cast(attrs, [
      :name,
      :type,
      :url,
      :confidence,
      :discovered_via,
      :discovered_at,
      :status,
      :approved_at,
      :config_generated,
      :excluded_at,
      :exclusion_email
    ])
    |> validate_required([:name, :type, :url, :discovered_at, :status])
    |> validate_inclusion(:type, ~w(bookshop community review_site event_source rss_feed))
    |> validate_inclusion(:status, ~w(pending_review approved dismissed excluded))
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> unique_constraint(:url)
  end

  @doc "Changeset for updating discovered source status."
  @spec discovered_source_status_changeset(DiscoveredSource.t(), map()) :: Ecto.Changeset.t()
  def discovered_source_status_changeset(%DiscoveredSource{} = source, attrs) do
    source
    |> cast(attrs, [
      :status,
      :approved_at,
      :excluded_at,
      :exclusion_email,
      :exclusion_requested_at
    ])
    |> validate_required([:status])
  end

  @doc "Changeset for updating discovered source confidence score."
  @spec discovered_source_confidence_changeset(DiscoveredSource.t(), map()) :: Ecto.Changeset.t()
  def discovered_source_confidence_changeset(%DiscoveredSource{} = source, attrs) do
    source
    |> cast(attrs, [:confidence])
    |> validate_required([:confidence])
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end

  @review_snapshot_required_fields [:book_id, :source, :source_url, :scraped_at]
  @review_snapshot_optional_fields [
    :sentiment_score,
    :summary,
    :rating,
    :rating_count,
    :stale_after
  ]

  # ⛔ The sanctioned-source policy (US-2.1.1 §4, ruling D6), enforced where the
  # write is — not in a fetcher, because a policy enforced only in the fetcher
  # lasts until the next fetcher, exactly as the ISBN hard gate lives in the
  # write (`Books.merge_edition/2`) rather than its callers. A source is
  # sanctioned only when we hold a standing, checkable right: open data, an
  # official API within its terms, consent, or a syndication feed. The proto
  # `ReviewSource` enum still names GOODREADS and STORYGRAPH (field numbers are
  # forever), but no sanctioned write may produce them — this is why.
  @sanctioned_sources ~w(open_library reddit partner author_rss)

  # Sources with a FIXED origin are pinned to their host(s); a snapshot cannot
  # claim one of these while linking elsewhere. `partner` and `author_rss` carry
  # variable hosts (their right comes from consent/syndication, not one domain),
  # so they are validated only for a well-formed http(s) URL.
  @source_hosts %{
    "open_library" => ["openlibrary.org"],
    "reddit" => ["reddit.com", "redd.it"]
  }

  @doc "The review sources we hold a standing, checkable right to (US-2.1.1 §4)."
  @spec sanctioned_sources() :: [String.t()]
  def sanctioned_sources, do: @sanctioned_sources

  @doc "Changeset for creating or updating a review snapshot."
  @spec review_snapshot_changeset(ReviewSnapshot.t(), map()) :: Ecto.Changeset.t()
  def review_snapshot_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, @review_snapshot_required_fields ++ @review_snapshot_optional_fields)
    |> validate_required(@review_snapshot_required_fields)
    |> validate_length(:summary, max: 500)
    |> validate_inclusion(:source, @sanctioned_sources,
      message: "is not a sanctioned review source (US-2.1.1 §4, ruling D6)"
    )
    |> validate_source_url_host()
    |> foreign_key_constraint(:book_id)
  end

  defp validate_source_url_host(changeset) do
    source = get_field(changeset, :source)
    url = get_field(changeset, :source_url)

    cond do
      is_nil(source) or is_nil(url) ->
        # required-field validation already reports the missing value.
        changeset

      not Map.has_key?(@source_hosts, source) ->
        # variable-host sanctioned source (partner / author_rss): require a
        # parseable http(s) URL, but do not pin a domain it may legitimately vary.
        if parseable_http_url?(url),
          do: changeset,
          else: add_error(changeset, :source_url, "is not a valid http(s) URL")

      host_allowed?(url, Map.fetch!(@source_hosts, source)) ->
        changeset

      true ->
        add_error(
          changeset,
          :source_url,
          "host does not belong to the #{source} source — a snapshot may not claim a sanctioned source while linking elsewhere"
        )
    end
  end

  defp parseable_http_url?(url) do
    case URI.parse(url) do
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) and h != "" -> true
      _ -> false
    end
  end

  defp host_allowed?(url, allowed) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        host = String.downcase(host)
        Enum.any?(allowed, fn a -> host == a or String.ends_with?(host, "." <> a) end)

      _ ->
        false
    end
  end

  @doc """
  The latest review snapshot per source for a book, newest first.

  ⛔ Filters to `sanctioned_sources/0` at READ time as well as write time, so a
  source that is DE-sanctioned (removed from the list) stops being displayed
  without a data migration — "a source list that can only grow is not a policy"
  (US-2.1.1 §4). A snapshot written while its source was sanctioned, whose source
  later leaves the list, simply stops appearing.
  """
  @spec list_sanctioned_reviews(binary()) :: [ReviewSnapshot.t()]
  def list_sanctioned_reviews(book_id) when is_binary(book_id) do
    from(r in ReviewSnapshot,
      where: r.book_id == ^book_id and r.source in ^@sanctioned_sources,
      order_by: [desc: r.scraped_at]
    )
    |> Repo.all()
    |> Enum.uniq_by(& &1.source)
  end

  @open_library_works_url "https://openlibrary.org/works"

  @doc """
  Fetch Open Library ratings for a book's OL work and store them as the
  `open_library` review snapshot (the preferred first sanctioned source,
  US-2.1.1 §4). Open Library returns an average rating and a count and no
  sentiment text, so the snapshot carries a rating and a count and nothing it
  would have to summarise. The write goes through `review_snapshot_changeset/2`,
  so the sanctioned-source gate applies to this path like any other.
  """
  @spec fetch_open_library_reviews(binary(), binary()) ::
          {:ok, ReviewSnapshot.t()} | {:error, term()}
  def fetch_open_library_reviews(book_id, work_id)
      when is_binary(book_id) and is_binary(work_id) do
    url = "#{@open_library_works_url}/#{work_id}/ratings.json"

    case review_http_client().get(url) do
      {:ok, %{"summary" => %{"count" => count} = summary}}
      when is_integer(count) and count > 0 ->
        %ReviewSnapshot{}
        |> review_snapshot_changeset(%{
          book_id: book_id,
          source: "open_library",
          source_url: "#{@open_library_works_url}/#{work_id}",
          rating: summary["average"],
          rating_count: count,
          scraped_at: DateTime.utc_now()
        })
        |> Repo.insert(
          on_conflict: {:replace, [:rating, :rating_count, :source_url, :scraped_at]},
          conflict_target: [:book_id, :source]
        )

      {:ok, _} ->
        {:error, :no_ratings}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp review_http_client,
    do: Application.get_env(:core, :isbn_http_client, Stacks.Books.HttpClient)

  @price_snapshot_required_fields [
    :book_edition_id,
    :book_id,
    :store_id,
    :price_cents,
    :scraped_at
  ]
  @price_snapshot_optional_fields [:currency, :in_stock, :url]

  @doc "Changeset for creating or updating a price snapshot."
  @spec price_snapshot_changeset(PriceSnapshot.t(), map()) :: Ecto.Changeset.t()
  def price_snapshot_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, @price_snapshot_required_fields ++ @price_snapshot_optional_fields)
    |> validate_required(@price_snapshot_required_fields)
    |> validate_number(:price_cents, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:book_edition_id)
    |> foreign_key_constraint(:book_id)
    |> foreign_key_constraint(:store_id)
    |> unique_constraint([:book_edition_id, :store_id])
  end

  @bookstore_event_required_fields [:store_id, :title, :scraped_at]
  @bookstore_event_optional_fields [:event_date, :description, :location, :url, :author_id]

  @doc "Changeset for creating or updating a bookstore event."
  @spec bookstore_event_changeset(BookstoreEvent.t(), map()) :: Ecto.Changeset.t()
  def bookstore_event_changeset(event, attrs) do
    event
    |> cast(attrs, @bookstore_event_required_fields ++ @bookstore_event_optional_fields)
    |> validate_required(@bookstore_event_required_fields)
    |> foreign_key_constraint(:store_id)
    |> foreign_key_constraint(:author_id)
  end

  @third_space_required_fields [:name, :type]
  @third_space_optional_fields [
    :city,
    :country_code,
    :instagram_url,
    :website_url,
    :description,
    :discovered_via,
    :verified,
    :last_active_at,
    :opted_out,
    :opted_out_at,
    :latitude,
    :longitude,
    :nearest_bookshop_km,
    :curated,
    :curated_note
  ]

  @doc "Changeset for creating or updating a third space."
  @spec third_space_changeset(ThirdSpace.t(), map()) :: Ecto.Changeset.t()
  def third_space_changeset(space, attrs) do
    space
    |> cast(attrs, @third_space_required_fields ++ @third_space_optional_fields)
    |> validate_required(@third_space_required_fields)
  end

  @third_space_event_required_fields [:space_id, :title, :event_date, :scraped_at]
  @third_space_event_optional_fields [
    :description,
    :recurrence,
    :related_authors,
    :source_url,
    :ends_at
  ]

  @doc "Changeset for creating or updating a third space event."
  @spec third_space_event_changeset(ThirdSpaceEvent.t(), map()) :: Ecto.Changeset.t()
  def third_space_event_changeset(event, attrs) do
    event
    |> cast(attrs, @third_space_event_required_fields ++ @third_space_event_optional_fields)
    |> validate_required(@third_space_event_required_fields)
    |> foreign_key_constraint(:space_id)
  end

  @doc """
      Lists third spaces with upcoming events preloaded. Options: `:lat`/
      `:lng`/`:radius_km` (point search), `:north`/`:south`/`:east`/`:west`
      (map viewport), `:near_bookshop_km` (rule is `0.5`),
      `:types`, `:limit` (default 20). Positions come from the STORED
      `latitude`/`longitude` written at approval time — never from city-name
      lookup — and `limit` is applied after all filters. Spaces without
      coordinates are excluded from geo queries but returned by unfiltered
      lists.
  """
  @spec list_third_spaces(keyword()) :: [ThirdSpace.t()]
  def list_third_spaces(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    ThirdSpace
    |> where([s], s.opted_out == false or is_nil(s.opted_out))
    |> filter_types(Keyword.get(opts, :types))
    |> filter_near_bookshop(Keyword.get(opts, :near_bookshop_km))
    |> filter_bounds(bounds_for(opts))
    |> Repo.all()
    |> refine_by_radius(opts)
    |> Enum.take(limit)
    |> preload_upcoming_events()
  end

  defp filter_types(query, nil), do: query
  defp filter_types(query, []), do: query
  defp filter_types(query, types) when is_list(types), do: where(query, [s], s.type in ^types)

  @curated_within_km 2.0

  defp filter_near_bookshop(query, nil), do: query

  defp filter_near_bookshop(query, km) when is_number(km) do
    outer = max(km, @curated_within_km)

    where(
      query,
      [s],
      not is_nil(s.nearest_bookshop_km) and
        (s.nearest_bookshop_km <= ^km or
           (s.curated == true and s.nearest_bookshop_km <= ^outer))
    )
  end

  @doc """
      The outer bound for curated spaces beyond the primary radius.

      Exposed so the rule is inspectable rather than a number buried in a query — and so a
      test can assert it is finite, which is what stops "curated" quietly meaning "anywhere".
  """
  @spec curated_within_km() :: float()
  def curated_within_km, do: @curated_within_km

  defp bounds_for(opts) do
    lat = Keyword.get(opts, :lat)
    lng = Keyword.get(opts, :lng)
    radius = Keyword.get(opts, :radius_km)

    cond do
      is_number(lat) and is_number(lng) and is_number(radius) ->
        box_around(lat, lng, radius)

      viewport?(opts) ->
        {Keyword.get(opts, :south), Keyword.get(opts, :north), Keyword.get(opts, :west),
         Keyword.get(opts, :east)}

      true ->
        nil
    end
  end

  defp viewport?(opts) do
    Enum.all?([:north, :south, :east, :west], &is_number(Keyword.get(opts, &1)))
  end

  defp box_around(lat, lng, radius_km) do
    dlat = radius_km / 111.0
    cos_lat = max(:math.cos(deg_to_rad(lat)), 0.01)
    dlng = radius_km / (111.0 * cos_lat)

    {lat - dlat, lat + dlat, lng - dlng, lng + dlng}
  end

  defp filter_bounds(query, nil), do: order_by(query, [s], asc: s.name)

  defp filter_bounds(query, {south, north, west, east}) do
    query
    |> where([s], not is_nil(s.latitude) and not is_nil(s.longitude))
    |> where([s], s.latitude >= ^south and s.latitude <= ^north)
    |> apply_longitude_bounds(west, east)
    |> order_by([s], asc: s.name)
  end

  defp apply_longitude_bounds(query, west, east) when west <= east,
    do: where(query, [s], s.longitude >= ^west and s.longitude <= ^east)

  defp apply_longitude_bounds(query, west, east),
    do: where(query, [s], s.longitude >= ^west or s.longitude <= ^east)

  defp refine_by_radius(spaces, opts) do
    lat = Keyword.get(opts, :lat)
    lng = Keyword.get(opts, :lng)
    radius = Keyword.get(opts, :radius_km)

    if is_number(lat) and is_number(lng) and is_number(radius) do
      Enum.filter(spaces, fn s ->
        is_number(s.latitude) and is_number(s.longitude) and
          haversine_km(lat, lng, s.latitude, s.longitude) <= radius
      end)
    else
      spaces
    end
  end

  defp preload_upcoming_events([]), do: []

  defp preload_upcoming_events(spaces) do
    now = DateTime.utc_now()
    space_ids = Enum.map(spaces, & &1.id)

    events_by_space =
      from(e in ThirdSpaceEvent,
        where: e.space_id in ^space_ids and e.event_date > ^now,
        order_by: [asc: e.event_date]
      )
      |> Repo.all()
      |> Enum.group_by(& &1.space_id)

    Enum.map(spaces, fn space ->
      Map.put(space, :upcoming_events, Map.get(events_by_space, space.id, []))
    end)
  end

  @earth_radius_km 6371.0

  @doc """
      Great-circle distance in kilometres between two points.

      Public because two contexts need it: the map's radius refinement here, and
      `Discovery.create_third_space/1`'s nearest-bookshop pairing. It was private and unused
      for months while `within_radius?/4` fed it coordinates from a hardcoded six-entry city
      map — the function was correct all along; only its inputs were wrong.
  """
  @spec haversine_km(number(), number(), number(), number()) :: float()
  def haversine_km(lat1, lng1, lat2, lng2) do
    dlat = deg_to_rad(lat2 - lat1)
    dlng = deg_to_rad(lng2 - lng1)
    rlat1 = deg_to_rad(lat1)
    rlat2 = deg_to_rad(lat2)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(rlat1) * :math.cos(rlat2) * :math.sin(dlng / 2) * :math.sin(dlng / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    @earth_radius_km * c
  end

  defp deg_to_rad(deg), do: deg * :math.pi() / 180.0

  @doc """
      Returns partner inventory for all editions of a book where quantity > 0
      and the partner is approved.
  """
  @spec book_availability(binary()) :: [map()]
  def book_availability(book_id) do
    from(i in InventoryItem,
      join: p in Partner,
      on: p.id == i.partner_id,
      join: e in BookEdition,
      on: e.id == i.book_edition_id,
      where: e.book_id == ^book_id,
      where: p.status == "approved",
      where: i.quantity > 0,
      select: %{
        partner: p.name,
        edition: e.isbn,
        price_cents: i.price_cents,
        condition: i.condition,
        quantity: i.quantity
      }
    )
    |> Repo.all()
  end
end
