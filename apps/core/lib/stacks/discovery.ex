defmodule Stacks.Discovery do
  @moduledoc """
  Context for managing discovered sources — bookshops, review sites,
  community spaces, and event sources found via automated search.

  Handles CRUD, deduplication by URL, status transitions, and the
  unauthenticated business opt-out flow.
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Enrichment.DiscoveredSource

  # ---------------------------------------------------------------------------
  # Create
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new discovered source with `status: :pending_review` and
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
        |> Map.put_new(:status, :pending_review)
        |> Map.put_new(:discovered_at, now)

      %DiscoveredSource{}
      |> DiscoveredSource.changeset(attrs)
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
    Repo.all(from(s in DiscoveredSource, where: s.status == :pending_review))
  end

  @doc """
  Returns approved sources matching the given city and/or country code.

  Searches the `discovered_via` field for location context. Both parameters
  are optional — if both are nil, returns all approved sources.
  """
  @spec sources_for_location(String.t() | nil, String.t() | nil) :: [DiscoveredSource.t()]
  def sources_for_location(city, country_code) do
    query = from(s in DiscoveredSource, where: s.status == :approved)

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
    |> DiscoveredSource.status_changeset(attrs)
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
    |> DiscoveredSource.confidence_changeset(%{confidence: confidence})
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Opt-out
  # ---------------------------------------------------------------------------

  @doc """
  Opts a source out by URL. Sets `status: :excluded`, `excluded_at`, and
  `exclusion_email`. The URL must match an existing discovered source.

  Returns `{:error, :not_found}` if no source matches the URL.
  Returns `{:error, :invalid_email}` if the email format is invalid.
  """
  @spec opt_out(String.t(), map()) ::
          {:ok, DiscoveredSource.t()} | {:error, :not_found | :invalid_email | Ecto.Changeset.t()}
  def opt_out(url, %{email: email} = _params) when is_binary(url) and is_binary(email) do
    if valid_email?(email) do
      case get_source_by_url(url) do
        nil ->
          {:error, :not_found}

        source ->
          update_source_status(source, %{
            status: :excluded,
            excluded_at: DateTime.utc_now(),
            exclusion_email: email
          })
      end
    else
      {:error, :invalid_email}
    end
  end

  defp valid_email?(email) do
    # Simple email format validation
    Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email)
  end
end
