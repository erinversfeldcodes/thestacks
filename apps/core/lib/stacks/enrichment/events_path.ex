defmodule Stacks.Enrichment.EventsPath do
  @moduledoc """
    Works out where a bookshop's events actually live, and remembers it.
    The old pipeline hardcoded `/events`, which 404s on every scrapeable
    store — zero rows, unnoticed, because tests fed fixture bodies. Guessing
    harder costs the shop a full render (a Shopify 404 is ~250KB styled), so
    the shop is ASKED: robots.txt declares the sitemap, the sitemap says
    which pages exist, one candidate is verified with one fetch. The answer
    is persisted on the store row (`events_path` / `events_path_checked_at`)
    and re-checked only after `@recheck_after_days`. "No events page" is a
    remembered answer too, not a retry.
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Enrichment.Bookstore
  alias Stacks.Enrichment.Prices

  require Logger

  @doc """
    Words that mark a URL as a plausible events page, best first.

    Ordered, and the order is the scoring: `events` beats `whats-on` beats `calendar`, so a shop with
    both `/pages/events` and `/pages/calendar` gets the one more likely to be a listing rather than an
    opening-hours page.

    Public so a test can enumerate them rather than restating the list — a duplicated list drifts, and
    the drift is silent.
  """
  @candidate_tokens ~w(events whats-on what-s-on whatson calendar diary programme program happenings)
  def candidate_tokens, do: @candidate_tokens

  @doc """
    How long a verdict — positive or negative — is trusted before it is checked again.

    This is what `events_path_checked_at` is *for*. Without a window the timestamp is written and never
    read, which is where this module started: it documented at length that a stale check should be
    revisited, and then nothing revisited anything.

    Thirty days is chosen from what the verdicts are about. A bookshop that adds an events page should
    be found within a month; a resolved path that quietly dies — a 500, or a redirect to the homepage,
    neither of which the job's 404 branch catches — should not persist for longer than that. One request
    per store per month is not a cost worth optimising away.
  """
  @recheck_after_days 30
  def recheck_after_days, do: @recheck_after_days

  @doc """
    Resolve and persist this store's events path.

    Returns `{:ok, path}` when a candidate was found and verified, or `{:error, reason}`. Every outcome
    is written to the store, so this is safe (and cheap) to call on every run — a store that already
    has an `events_path` short-circuits without touching the network at all.
  """
  @spec resolve(Bookstore.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve(%Bookstore{events_path: path} = store) when is_binary(path) and path != "" do
    if stale?(store) do
      Logger.info("EventsPath: re-verifying #{store.name || store.id}'s #{path} (stale)")
      verify(store, store.name || store.id, path)
    else
      {:ok, path}
    end
  end

  def resolve(%Bookstore{} = store) do
    store_name = store.name || store.id

    if stale?(store) do
      walk(store, store_name)
    else
      Logger.info(
        "EventsPath: #{store_name} was checked within #{@recheck_after_days} days and had no " <>
          "events page; not asking again yet"
      )

      {:error, :recently_checked}
    end
  end

  defp stale?(%Bookstore{events_path_checked_at: nil}), do: true

  defp stale?(%Bookstore{events_path_checked_at: at}) do
    DateTime.diff(DateTime.utc_now(), at, :day) >= @recheck_after_days
  end

  defp walk(store, store_name) do
    case client().sitemap_urls(store.scraper_module) do
      {:ok, %{documents_fetched: 0} = harvest} ->
        detail = harvest |> Map.get(:skipped, []) |> Enum.take(1) |> Enum.join("; ")
        unresolved(store, "could not read the shop's sitemap — could not look (#{detail})")
        {:error, :sitemap_unreadable}

      {:ok, %{urls: urls, truncated: truncated}} ->
        resolve_from(store, store_name, urls, truncated)

      {:error, :no_sitemap_declared} ->
        unresolved(store, "no sitemap declared in robots.txt — could not look")
        {:error, :no_sitemap_declared}

      {:error, {:rate_limited, retry_after}} ->
        unresolved(store, "shop asked us to back off for #{retry_after}s — could not look")
        {:error, {:rate_limited, retry_after}}

      {:error, {:robots_blocked, rule}} ->
        unresolved(store, "robots.txt blocks the sitemap (#{rule})")
        {:error, {:robots_blocked, rule}}

      {:error, reason} ->
        unresolved(store, "sitemap walk failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp resolve_from(store, store_name, urls, truncated) do
    case best_candidate(urls) do
      nil when truncated ->
        unresolved(store, "no candidate in a truncated walk — budget ran out, retry later")
        {:error, {:no_candidate, urls}}

      nil ->
        Logger.info(
          "EventsPath: #{store_name} lists #{length(urls)} page(s), none an events page"
        )

        unresolved(store, "no candidate matched among #{length(urls)} listed page(s)")
        {:error, {:no_candidate, urls}}

      candidate ->
        verify(store, store_name, candidate)
    end
  end

  @doc """
    Pick the most plausible events URL from a list of page URLs.

    Pure, and separated from the fetching for the usual reason: this is the part with a judgement in it,
    and a judgement that cannot be tested without a network is a judgement nobody checks.

    Scored by `@candidate_tokens` order, then by path depth — `/pages/events` beats
    `/pages/events/2024-archive`, because the shallower path is the listing and the deeper one is a
    page within it.
  """
  @spec best_candidate([String.t()]) :: String.t() | nil
  def best_candidate(urls) do
    urls
    |> Enum.flat_map(fn url ->
      lower = String.downcase(url)

      case Enum.find_index(@candidate_tokens, &String.contains?(lower, &1)) do
        nil -> []
        rank -> [{rank, depth(url), url}]
      end
    end)
    |> Enum.min_by(fn {rank, depth, url} -> {rank, depth, url} end, fn -> nil end)
    |> case do
      nil -> nil
      {_rank, _depth, url} -> url
    end
  end

  defp depth(url), do: url |> String.split("/") |> length()

  defp verify(store, store_name, candidate) do
    path = if String.starts_with?(candidate, "/"), do: candidate, else: path_of(candidate)

    case client().fetch_page(store.scraper_module, path) do
      {:ok, %{status: 200}} ->
        Logger.info("EventsPath: #{store_name} events page resolved to #{path}")
        record_path(store, path)
        {:ok, path}

      {:ok, %{status: status}} ->
        unresolved(store, "sitemap listed #{path} but it answered HTTP #{status}")
        {:error, :unverified}

      {:error, {:rate_limited, retry_after}} ->
        unresolved(store, "shop asked us to back off for #{retry_after}s during verification")
        {:error, {:rate_limited, retry_after}}

      {:error, {:robots_blocked, rule}} ->
        Prices.record_robots_block(store, path, rule)
        unresolved(store, "robots.txt blocks #{path} (#{rule})")
        {:error, {:robots_blocked, rule}}

      {:error, reason} ->
        unresolved(store, "verification of #{path} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
    Store the cache validators a fetch came back with, so the next one can be conditional.

    Written on a 200 *and* on a 304: an origin may rotate an ETag alongside a 304, and keeping the stale
    one would make every subsequent request unconditional again — the saving would quietly stop without
    anything failing.

    Absent validators are stored as absent rather than skipped. If a shop stops sending an ETag, holding
    the old one means sending `If-None-Match` for a validator the origin no longer recognises, which at
    best does nothing and at worst gets a 200 the shop had no need to render.
  """
  @spec remember_validators(Bookstore.t(), map()) :: :ok
  def remember_validators(%Bookstore{} = store, response) do
    stamp(store,
      events_page_etag: Map.get(response, :etag, ""),
      events_page_last_modified: Map.get(response, :last_modified, "")
    )
  end

  @doc """
    Forget a resolved path, so the next run re-resolves it.

    Called when a previously-working path stops serving. `resolve/1` deliberately does **not**
    re-verify a known path on every run — that would restore the per-store-per-run request cost this
    module exists to remove — so the recheck has to be triggered from where the failure actually
    appears, which is the fetch in `DiscoverBookstoreEventsJob`.

    The reason is recorded rather than the field merely nulled: a path that vanished is a different
    situation from one that was never found, and an operator seeing an empty `events_path` with no
    explanation cannot tell which.
  """
  @spec forget(Bookstore.t()) :: :ok
  def forget(%Bookstore{} = store) do
    stamp(store, events_page_etag: "", events_page_last_modified: "")
    unresolved(store, "previously resolved path stopped serving; will re-resolve")
  end

  @doc """
    The path part of an absolute URL — what the compliant egress takes.

    `/` for a bare host, so a caller never builds `nil` into a request. Note the egress resolves this
    against the store's *configured* base URL, which is why only the path travels: a full URL would let
    a sitemap steer our requests at another host.
  """
  @spec path_of(String.t()) :: String.t()
  def path_of(url) do
    case String.split(url, "/", parts: 4) do
      ["https:" <> _, "", _host, rest] -> "/" <> rest
      ["http:" <> _, "", _host, rest] -> "/" <> rest
      _ -> "/"
    end
  end

  defp record_path(store, path) do
    stamp(store, events_path: path, events_unresolved_reason: nil)
  end

  defp unresolved(store, reason) do
    Logger.info("EventsPath: #{store.name || store.id} unresolved — #{reason}")
    stamp(store, events_path: nil, events_unresolved_reason: reason)
  end

  defp stamp(store, fields) do
    fields = Keyword.put(fields, :events_path_checked_at, DateTime.utc_now())

    {1, _} =
      Bookstore
      |> where([b], b.id == ^store.id)
      |> Repo.update_all(set: fields)

    :ok
  end

  defp client, do: Application.get_env(:core, :scraper_client, Stacks.Enrichment.ScraperClient)
end
