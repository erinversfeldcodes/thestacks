defmodule Stacks.Enrichment.Events do
  @moduledoc """
  Context for event enrichment — manages scraped event listings at bookstores
  and third spaces.

  Bookstore events are upserted on `(store_id, title, event_date)` to prevent
  duplicate entries from re-scraping. Third space events are upserted on
  `(space_id, title, event_date)`.
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Enrichment
  alias Stacks.Enrichment.{BookstoreEvent, ThirdSpaceEvent}

  @doc """
  Inserts a new bookstore event or updates the existing one for the same
  `(store_id, title, event_date)` triple.

  Returns `{:ok, event}` on success, `{:error, changeset}` on validation failure.
  """
  @spec upsert_event(map()) :: {:ok, BookstoreEvent.t()} | {:error, Ecto.Changeset.t()}
  def upsert_event(attrs) do
    %BookstoreEvent{}
    |> Enrichment.bookstore_event_changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:description, :location, :url, :author_id, :scraped_at]},
      conflict_target: [:store_id, :title, :event_date],
      returning: true
    )
  end

  @doc """
  Returns upcoming bookstore events for the given store_id.
  Events are ordered by event_date ascending.
  """
  @spec upcoming_events(String.t()) :: [BookstoreEvent.t()]
  def upcoming_events(store_id) do
    now = DateTime.utc_now()

    BookstoreEvent
    |> where([e], e.store_id == ^store_id)
    |> where([e], e.event_date >= ^now)
    |> order_by([e], asc: e.event_date)
    |> Repo.all()
  end

  @doc """
  Every listed event for a store — dated (soonest first) and dateless.

  Distinct from `upcoming_events/1` on purpose. "Upcoming" is a claim about time, and a dateless
  event cannot honestly make it — counting one as upcoming would be a structurally valid payload
  asserting something we do not know. Dateless events sort last: a reader scanning for the next
  date should not trip over entries that have none, but the entries are real (the shop's own page
  carries the details) and belong in the list.
  """
  @spec listed_events(String.t()) :: [BookstoreEvent.t()]
  def listed_events(store_id) do
    now = DateTime.utc_now()

    BookstoreEvent
    |> where([e], e.store_id == ^store_id)
    |> where([e], is_nil(e.event_date) or e.event_date >= ^now)
    |> order_by([e], asc_nulls_last: e.event_date)
    |> Repo.all()
  end

  @doc """
  Every listed event linked to an author, dated (soonest first) then dateless —
  the read behind the book-detail author card (#321 item 4: "surface events").
  `listed_events/1` semantics, author-keyed: a dateless event is listed, not
  "upcoming" — it cannot honestly make a claim about time.
  """
  @spec listed_events_for_author(String.t()) :: [BookstoreEvent.t()]
  def listed_events_for_author(author_id) do
    now = DateTime.utc_now()

    BookstoreEvent
    |> where([e], e.author_id == ^author_id)
    |> where([e], is_nil(e.event_date) or e.event_date >= ^now)
    |> order_by([e], asc_nulls_last: e.event_date)
    |> Repo.all()
  end

  @doc """
  Inserts a new third space event or updates the existing one for the same
  `(space_id, title, event_date)` triple.

  Returns `{:ok, event}` on success, `{:error, changeset}` on validation failure.
  """
  @spec upsert_third_space_event(map()) ::
          {:ok, ThirdSpaceEvent.t()} | {:error, Ecto.Changeset.t()}
  def upsert_third_space_event(attrs) do
    %ThirdSpaceEvent{}
    |> Enrichment.third_space_event_changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace, [:description, :recurrence, :related_authors, :source_url, :scraped_at]},
      conflict_target: [:space_id, :title, :event_date],
      returning: true
    )
  end

  @doc """
  Returns upcoming third space events for the given space_id.
  Events are ordered by event_date ascending.
  """
  @spec upcoming_third_space_events(String.t()) :: [ThirdSpaceEvent.t()]
  def upcoming_third_space_events(space_id) do
    now = DateTime.utc_now()

    ThirdSpaceEvent
    |> where([e], e.space_id == ^space_id)
    |> where([e], e.event_date >= ^now)
    |> order_by([e], asc: e.event_date)
    |> Repo.all()
  end
end
