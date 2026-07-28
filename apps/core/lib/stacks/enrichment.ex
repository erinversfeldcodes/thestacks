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

  # ── DiscoveredSource ───────────────────────────────────────────────────────

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
    # `exclusion_requested_at` is castable so a removal request can be recorded without
    # applying it — the pending state for an unverified request.
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

  # ── ReviewSnapshot ─────────────────────────────────────────────────────────

  @review_snapshot_required_fields [:book_id, :source, :source_url, :scraped_at]
  @review_snapshot_optional_fields [
    :sentiment_score,
    :summary,
    :rating,
    :rating_count,
    :stale_after
  ]

  @doc "Changeset for creating or updating a review snapshot."
  @spec review_snapshot_changeset(ReviewSnapshot.t(), map()) :: Ecto.Changeset.t()
  def review_snapshot_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, @review_snapshot_required_fields ++ @review_snapshot_optional_fields)
    |> validate_required(@review_snapshot_required_fields)
    |> validate_length(:summary, max: 500)
    |> foreign_key_constraint(:book_id)
  end

  # ── PriceSnapshot ──────────────────────────────────────────────────────────

  # `book_edition_id` is the grain: a price belongs to an edition, not a work.
  # `book_id` is required too, but it is derived from the edition by
  # `Prices.upsert_snapshot/1` rather than supplied — see the note there.
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

  # ── BookstoreEvent ─────────────────────────────────────────────────────────

  @bookstore_event_required_fields [:store_id, :title, :event_date, :scraped_at]
  @bookstore_event_optional_fields [:description, :location, :url, :author_id]

  @doc "Changeset for creating or updating a bookstore event."
  @spec bookstore_event_changeset(BookstoreEvent.t(), map()) :: Ecto.Changeset.t()
  def bookstore_event_changeset(event, attrs) do
    event
    |> cast(attrs, @bookstore_event_required_fields ++ @bookstore_event_optional_fields)
    |> validate_required(@bookstore_event_required_fields)
    |> foreign_key_constraint(:store_id)
    |> foreign_key_constraint(:author_id)
  end

  # ── ThirdSpace ─────────────────────────────────────────────────────────────

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
    :opted_out_at
  ]

  @doc "Changeset for creating or updating a third space."
  @spec third_space_changeset(ThirdSpace.t(), map()) :: Ecto.Changeset.t()
  def third_space_changeset(space, attrs) do
    space
    |> cast(attrs, @third_space_required_fields ++ @third_space_optional_fields)
    |> validate_required(@third_space_required_fields)
  end

  # ── ThirdSpaceEvent ────────────────────────────────────────────────────────

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

  # ── Queries ──────────────────────────────────────────────────────────────────

  # Known city coordinates for Haversine geo filtering (MVP — no PostGIS).
  @city_coords %{
    "Cape Town" => {-33.9249, 18.4241},
    "Johannesburg" => {-26.2041, 28.0473},
    "Pretoria" => {-25.7479, 28.2293},
    "Durban" => {-29.8587, 31.0218},
    "Stellenbosch" => {-33.9321, 18.8602},
    "Franschhoek" => {-33.8734, 19.1169}
  }

  @doc """
  Lists third spaces with upcoming events preloaded.

  Options:
    * `:lat`, `:lng`, `:radius_km` — filter by distance from a point (uses city lookup)
    * `:limit` — max results (default 20)
  """
  @spec list_third_spaces(keyword()) :: [ThirdSpace.t()]
  def list_third_spaces(opts \\ []) do
    now = DateTime.utc_now()
    limit = Keyword.get(opts, :limit, 20)

    spaces =
      ThirdSpace
      |> limit(^limit)
      |> Repo.all()

    space_ids = Enum.map(spaces, & &1.id)

    events_by_space =
      from(e in ThirdSpaceEvent,
        where: e.space_id in ^space_ids,
        where: e.event_date > ^now,
        order_by: [asc: e.event_date]
      )
      |> Repo.all()
      |> Enum.group_by(& &1.space_id)

    spaces =
      Enum.map(spaces, fn space ->
        Map.put(space, :upcoming_events, Map.get(events_by_space, space.id, []))
      end)

    case {Keyword.get(opts, :lat), Keyword.get(opts, :lng), Keyword.get(opts, :radius_km)} do
      {lat, lng, radius_km} when is_number(lat) and is_number(lng) and is_number(radius_km) ->
        Enum.filter(spaces, &within_radius?(&1, lat, lng, radius_km))

      _ ->
        spaces
    end
  end

  defp within_radius?(space, lat, lng, radius_km) do
    case Map.get(@city_coords, space.city) do
      {city_lat, city_lng} -> haversine_km(lat, lng, city_lat, city_lng) <= radius_km
      nil -> false
    end
  end

  @earth_radius_km 6371.0

  defp haversine_km(lat1, lng1, lat2, lng2) do
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
