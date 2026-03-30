defmodule Stacks.Enrichment do
  @moduledoc """
  Unified context for enrichment changeset functions.

  Changeset logic lives here rather than in the schema modules so that
  schemas can be replaced by auto-generated code while validation rules
  remain hand-written and testable.
  """

  import Ecto.Changeset

  alias Stacks.Enrichment.BookstoreEvent
  alias Stacks.Enrichment.DiscoveredSource
  alias Stacks.Enrichment.PriceSnapshot
  alias Stacks.Enrichment.ReviewSnapshot
  alias Stacks.Enrichment.ThirdSpace
  alias Stacks.Enrichment.ThirdSpaceEvent

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
    |> cast(attrs, [:status, :approved_at, :excluded_at, :exclusion_email])
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

  @price_snapshot_required_fields [:book_id, :store_id, :price_cents, :scraped_at]
  @price_snapshot_optional_fields [:currency, :in_stock, :url]

  @doc "Changeset for creating or updating a price snapshot."
  @spec price_snapshot_changeset(PriceSnapshot.t(), map()) :: Ecto.Changeset.t()
  def price_snapshot_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, @price_snapshot_required_fields ++ @price_snapshot_optional_fields)
    |> validate_required(@price_snapshot_required_fields)
    |> validate_number(:price_cents, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:book_id)
    |> foreign_key_constraint(:store_id)
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
end
