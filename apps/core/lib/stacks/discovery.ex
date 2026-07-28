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
  alias Stacks.Enrichment.DiscoveredSource
  alias Stacks.Events

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

        case update_source_status(source, attrs) do
          {:ok, updated} = result ->
            Events.emit_safe(%{
              event_type: event_type,
              aggregate_type: "discovered_source",
              aggregate_id: updated.id,
              payload: %{status: to_string(target_status)}
            })

            result

          error ->
            error
        end

      %DiscoveredSource{} ->
        {:error, :invalid_transition}
    end
  end

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
        {:ok, updated} -> {:ok, :excluded, updated}
        other -> other
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
