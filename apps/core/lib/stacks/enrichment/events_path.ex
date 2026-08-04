defmodule Stacks.Enrichment.EventsPath do
  @moduledoc """
  Works out where a bookshop's events actually live, and remembers the answer.

  ## Why this exists

  `DiscoverBookstoreEventsJob` fetched one hardcoded path — `/events` — on every store, and it
  **404s on every scrapeable store**. The events pipeline had therefore never written a row, and no
  test noticed, because every test fed it a fixture body rather than a real shop.

  Guessing harder is not the answer. A wrong guess costs the shop a full page render — a Shopify 404
  is a *styled* page, measured at 249,540 bytes on 2026-07-29 — and there is no reason to think
  `/whats-on` or `/diary` would fare better than `/events` did.

  So the shop is asked instead of guessed at. robots.txt already declares its sitemap (read for
  compliance on every request, so learning this costs nothing), the sitemap says which pages exist,
  and one candidate is verified with one fetch.

  ## The interface, and what it hides

  One function, one argument, and the caller needs to know nothing about robots.txt, sitemap indexes,
  child-sitemap classification, crawl budgets or candidate scoring:

      EventsPath.resolve(store) :: {:ok, path} | {:error, reason}

  Behind it: `ScraperClient.sitemap_urls/1` (which itself hides the walk), a keyword filter, one
  verification fetch, and a write. The point of the module is that the *job* asking "where are this
  shop's events?" gets an answer rather than a procedure.

  ## Asked once, not once per run

  Every outcome is persisted — `events_path` on success, `events_unresolved_reason` otherwise, and
  `events_path_checked_at` either way. A shop that has no events page must cost us nothing on the
  next run, and it must not cost the shop anything either.

  ⚠️ **`events_path_checked_at` is what makes a negative verdict re-checkable rather than permanent.**
  An empty `events_path` on its own cannot distinguish "we looked and there is none" from "we have
  not looked yet", and treating the second as the first writes a shop off forever. A shop that adds
  an events page next month should be found.

  ## What is deliberately not treated as "no events page"

  This is the distinction the whole design turns on, and getting it wrong produces a false negative
  that never re-checks:

  | Outcome | Means | Recorded as |
  |---|---|---|
  | Candidates found, one verified | we know where events are | `events_path` |
  | Sitemap read, no candidate matched | the shop lists no events page | a *resolved* negative |
  | `:no_sitemap_declared` | **we could not look** | unresolved, retry later |
  | `truncated: true` | we ran out of budget mid-walk | unresolved, retry later |
  | `{:rate_limited, _}` | the shop asked us to wait | unresolved, retry later |

  Only the second row is a fact about the shop. The other three are facts about *our attempt*, and
  banking them as "this shop has no events" is how a temporary condition becomes a permanent verdict.
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
      # Re-verify rather than trust indefinitely. `forget/1` only fires on a 404, so a path that
      # starts answering 500 or redirecting to the homepage would otherwise be believed forever.
      Logger.info("EventsPath: re-verifying #{store.name || store.id}'s #{path} (stale)")
      verify(store, store.name || store.id, path)
    else
      # Fresh and known: no network at all. Re-testing a working path on every run is the per-store
      # per-run cost this module exists to remove.
      {:ok, path}
    end
  end

  def resolve(%Bookstore{} = store) do
    store_name = store.name || store.id

    # ⚠️ A *negative* verdict is trusted for the same window as a positive one, and this is the half
    # that matters for the shop. Without it, a bookshop with no events page pays for a fresh sitemap
    # walk on every single run, forever — which is the opposite of the courtesy this whole path was
    # built for. `events_path_checked_at` is what makes "we already asked" answerable.
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

  # Never checked, or checked longer ago than the window. `nil` is stale by definition: it means we
  # have not looked, which must never read as a fresh negative.
  defp stale?(%Bookstore{events_path_checked_at: nil}), do: true

  defp stale?(%Bookstore{events_path_checked_at: at}) do
    DateTime.diff(DateTime.utc_now(), at, :day) >= @recheck_after_days
  end

  defp walk(store, store_name) do
    case client().sitemap_urls(store.scraper_module) do
      # ⛔ `documents_fetched == 0` means we never successfully READ a sitemap — the shop declared one
      # and it did not serve. Found by the first live run (2026-08-04): exclusivebooks.co.za declares
      # `Sitemap:` three times and that sitemap answers **HTTP 500 with 0 bytes**. The harvest comes
      # back `HARVESTED` with an empty `urls` and the failure in `skipped`, so without this clause the
      # store was recorded as "no candidate matched among 0 listed page(s)" — i.e. as a shop with no
      # events page, on the strength of a document we could not open.
      #
      # That is the exact conflation this module exists to prevent, and it survived every unit test
      # because no fixture had a declared-but-unreadable sitemap. Only the live run had one.
      {:ok, %{documents_fetched: 0} = harvest} ->
        detail = harvest |> Map.get(:skipped, []) |> Enum.take(1) |> Enum.join("; ")
        unresolved(store, "could not read the shop's sitemap — could not look (#{detail})")
        {:error, :sitemap_unreadable}

      {:ok, %{urls: urls, truncated: truncated}} ->
        resolve_from(store, store_name, urls, truncated)

      # ⚠️ NOT "this shop has no events page". We were unable to look at all, and recording that as a
      # resolved negative is the false negative this module is shaped to avoid.
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
        # No candidate AND an incomplete walk. The two together are not evidence of absence: the
        # events page may well have been in the part we never read.
        unresolved(store, "no candidate in a truncated walk — budget ran out, retry later")
        {:error, {:no_candidate, urls}}

      nil ->
        # A real, resolved negative: we read the shop's page list and it contains no events page.
        # Recorded with a checked_at so it is re-checkable, not permanent.
        #
        # ⚠️ The harvested URLs travel WITH the negative. #382's live run proved these shops publish
        # events as individual pages, so "no listing page" is where per-page classification starts —
        # and the classifier reusing this walk's harvest is what keeps its cost at zero extra
        # requests to the shop. Returning a bare atom here would force a second walk for the same
        # answer.
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

  # One fetch, and only one. The candidate came from the shop's own list of pages, so it should
  # exist; verifying is about confirming it is reachable and not a redirect stub, not about searching.
  defp verify(store, store_name, candidate) do
    # Accepts either an absolute URL from a sitemap or an already-relative path from a re-verify —
    # `path_of/1` is idempotent on a path, so one function serves both callers rather than the caller
    # having to know which shape it holds.
    path = if String.starts_with?(candidate, "/"), do: candidate, else: path_of(candidate)

    case client().fetch_page(store.scraper_module, path) do
      {:ok, %{status: 200}} ->
        Logger.info("EventsPath: #{store_name} events page resolved to #{path}")
        record_path(store, path)
        {:ok, path}

      {:ok, %{status: status}} ->
        # The shop listed a page in its own sitemap that does not serve. Its problem, not a fact about
        # whether it holds events — so unresolved and re-checkable rather than a resolved negative.
        unresolved(store, "sitemap listed #{path} but it answered HTTP #{status}")
        {:error, :unverified}

      {:error, {:rate_limited, retry_after}} ->
        unresolved(store, "shop asked us to back off for #{retry_after}s during verification")
        {:error, {:rate_limited, retry_after}}

      # Unlike the walk-level block, the disallowed path is known here — it is the candidate we just
      # asked for — so this one is recorded as a real block on a real path. `Prices` stays the only
      # writer of that trio; this is a caller of it, not a second writer.
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
    # The validators go with the path. Keeping them would send `If-None-Match` for a URL we are about
    # to stop using, against a page that may not exist.
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

  # `events_path_checked_at` is stamped on EVERY outcome, success or not. It is what separates "we
  # looked and found nothing" from "we have not looked", so writing a reason without it would leave
  # exactly the ambiguity the reason exists to remove.
  # Named `stamp`, not `update` — `import Ecto.Query` brings in `update/2`, and a private function of
  # the same arity shadows it, so the `Repo.update_all` below fails to compile with a confusing
  # "malformed update" from inside the macro.
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
