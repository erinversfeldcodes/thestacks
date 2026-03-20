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
  alias Stacks.Enrichment.{BookstoreEvent, ThirdSpaceEvent}

  # ── Bookstore Events ────────────────────────────────────────────────────────

  @doc """
  Inserts a new bookstore event or updates the existing one for the same
  `(store_id, title, event_date)` triple.

  Returns `{:ok, event}` on success, `{:error, changeset}` on validation failure.
  """
  @spec upsert_event(map()) :: {:ok, BookstoreEvent.t()} | {:error, Ecto.Changeset.t()}
  def upsert_event(attrs) do
    %BookstoreEvent{}
    |> BookstoreEvent.changeset(attrs)
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

  # ── Third Space Events ──────────────────────────────────────────────────────

  @doc """
  Inserts a new third space event or updates the existing one for the same
  `(space_id, title, event_date)` triple.

  Returns `{:ok, event}` on success, `{:error, changeset}` on validation failure.
  """
  @spec upsert_third_space_event(map()) ::
          {:ok, ThirdSpaceEvent.t()} | {:error, Ecto.Changeset.t()}
  def upsert_third_space_event(attrs) do
    %ThirdSpaceEvent{}
    |> ThirdSpaceEvent.changeset(attrs)
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
