defmodule Stacks.Transparency do
  @moduledoc """
  Public, curated, anonymised transparency data layer (241 / ADR-019) for
  the public `/metrics` page: live ops signals + durable aggregates, never
  a per-user value. The privacy boundary is structural: live signals come
  ONLY from `@allowlist` (fixed, code-defined PromQL — `run_signal/1`
  accepts an allowlist KEY, no function takes a query string), and every
  family used must be classified `:public` in `Core.PromEx.MetricAudience`
  (enforced by test, fail-closed). Degrades to `:unavailable` when the
  metrics store is unreachable — public page, no errors, no leaks.
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Books.{Book, BookEdition}
  alias Stacks.Costs
  alias Stacks.Transparency.Cache

  @cache_ttl_seconds 45
  @cache_ttl_ms @cache_ttl_seconds * 1_000
  @live_cache_key :live_signals

  @default_app "thestacks-core"

  @allowlist [
    %{
      key: :isbn_not_found_rate,
      query:
        ~s|sum(rate(stacks_moderation_isbn_resolution_count_total{app="$app",outcome="isbn_not_found"}[1h]))|,
      label: "ISBN-not-found rate",
      what:
        "How often, per second over the last hour, a scanned book could not be matched to a verified ISBN.",
      how:
        "Counted at the moderation ISBN-resolution step and aggregated across the whole platform.",
      why:
        "It is the same signal operators watch to spot a broken book-data source — shown here so you see what we see.",
      unit: "per_second"
    },
    %{
      key: :moderation_throughput,
      query: ~s|sum(rate(stacks_moderation_classification_count_total{app="$app"}[1h]))|,
      label: "Moderation throughput",
      what:
        "How many uploads per second are being classified by the moderation pipeline this hour.",
      how:
        "Counted at the first moderation step (is-this-a-book classification), summed platform-wide.",
      why: "Shows how busy content moderation is — the pipeline every upload passes through.",
      unit: "per_second"
    },
    %{
      key: :age_gate_block_rate,
      query: ~s|sum(rate(stacks_age_gate_enforce_count_total{app="$app",outcome="blocked"}[1h]))|,
      label: "Age-gate blocks",
      what:
        "How often per second the age gate blocked access to an age-restricted book this hour.",
      how:
        "Counted only on enforcement decisions for age-gated books; aggregated, never per-user.",
      why: "Demonstrates the safety control working, without recording who was blocked.",
      unit: "per_second"
    },
    %{
      key: :breakers_healthy,
      query: ~s|min(stacks_fuse_state_state{app="$app"})|,
      label: "Circuit breakers healthy",
      what:
        "Whether every dependency circuit breaker is currently closed (1 = all healthy, 0 = one blown).",
      how: "The minimum of every breaker's state gauge — 0 if any single breaker has tripped.",
      why:
        "This is a core reliability signal operators use during an outage; we show it rather than hide it.",
      unit: "boolean"
    },
    %{
      key: :gdpr_export_rate_24h,
      query: ~s|sum(rate(stacks_gdpr_export_count_total{app="$app"}[24h]))|,
      label: "Data exports in progress",
      what: "The rate of GDPR data-export jobs over the last 24 hours.",
      how:
        "Counted per export job, aggregated platform-wide — no identity of the requester is attached.",
      why:
        "Data rights are a feature, not a formality: this shows the right-to-portability actually running.",
      unit: "per_second"
    },
    %{
      key: :handler_error_rate,
      query: ~s|sum(rate(stacks_events_handler_error_count_total{app="$app"}[1h]))|,
      label: "Background error rate",
      what: "How often per second a background event handler failed this hour.",
      how:
        "Counted whenever an event handler returns an error or raises, summed across all handlers.",
      why:
        "The signal we use to detect a silent breakage — shown so you can watch reliability alongside us.",
      unit: "per_second"
    }
  ]

  @entry_public_keys [:key, :label, :what, :how, :why, :unit, :value]

  @doc """
  Builds the full public transparency payload:

      %{
        live: [entry] | :unavailable,
        durable: [entry],
        generated_at: DateTime.t(),
        cache_ttl: pos_integer()
      }

  where each entry is `%{key, label, what, how, why, unit, value}`.
  """
  @spec metrics() :: %{
          live: [map()] | :unavailable,
          durable: [map()],
          generated_at: DateTime.t(),
          cache_ttl: pos_integer()
        }
  def metrics do
    %{
      live: cached_live_signals(),
      durable: durable_stats(),
      generated_at: DateTime.utc_now(),
      cache_ttl: @cache_ttl_seconds
    }
  end

  @doc "The fixed set of allowlist signal keys (atoms) — the only runnable live signals."
  @spec allowlist_keys() :: [atom()]
  def allowlist_keys, do: Enum.map(@allowlist, & &1.key)

  @doc """
  The raw PromQL of every allowlisted live signal. For introspection/tests only —
  e.g. proving every metric the public page exposes is `MetricAudience` `:public`.
  """
  @spec allowlist_queries() :: [String.t()]
  def allowlist_queries, do: Enum.map(@allowlist, & &1.query)

  @doc """
  Runs a single allowlisted live signal by KEY.

  Accepts only a allowlist key (atom) — never a raw/user-supplied PromQL string.
  Returns `{:error, :not_allowlisted}` for any key not in the fixed allowlist,
  so there is no path to run an arbitrary or injected query.
  """
  @spec run_signal(atom()) :: {:ok, number()} | {:error, term()}
  def run_signal(key) when is_atom(key) do
    case Enum.find(@allowlist, &(&1.key == key)) do
      nil -> {:error, :not_allowlisted}
      entry -> prometheus_client().query(scoped_query(entry.query))
    end
  end

  @doc """
  Public-safe durable aggregates read from op-data. All are corpus/cost totals —
  no per-user rows, no de-anonymisable or linked-account dimension.
  """
  @spec durable_stats() :: [map()]
  def durable_stats do
    books = Costs.book_count()

    [
      durable_entry(:total_books, books, "Books catalogued",
        what: "The total number of distinct works catalogued on the platform.",
        how: "A count of rows in the books table — a corpus total, not tied to any user.",
        why: "The simplest honest measure of what the library holds.",
        unit: "books"
      ),
      durable_entry(:total_editions, edition_count(), "Editions catalogued",
        what: "The total number of specific ISBN editions across all works.",
        how: "A count of rows in the book_editions table.",
        why: "Shows the breadth of formats and printings behind the catalogue.",
        unit: "editions"
      ),
      durable_entry(:pct_age_gated, pct_age_gated(books), "Share age-gated",
        what: "The percentage of catalogued works that are age-restricted.",
        how: "age_gated works divided by total works — an aggregate ratio, no user attached.",
        why: "Shows how much of the catalogue the age gate applies to, transparently.",
        unit: "percent"
      ),
      durable_entry(:books_shelved, Costs.placement_count(), "Books shelved",
        what: "The total number of times a book has been placed on any bookshelf.",
        how:
          "A count of bookshelf placements across all users — a platform total, never per-user.",
        why: "A measure of activity that reveals nothing about any individual reader.",
        unit: "placements"
      ),
      durable_entry(
        :platform_cost_cents,
        current_period_cost_cents(),
        "Platform cost this period",
        what: "What it currently costs, in USD cents, to run the platform this billing period.",
        how: "The sum of recorded infrastructure cost line items for the current month.",
        why:
          "Running a platform costs money — showing it is why 'free' platforms sell your data and this one does not.",
        unit: "usd_cents"
      )
    ]
  end

  defp cached_live_signals do
    case Cache.get(@live_cache_key, @cache_ttl_ms) do
      {:ok, cached} -> cached
      :miss -> refresh_live_signals()
    end
  end

  defp refresh_live_signals do
    case compute_live_signals() do
      {:ok, entries} ->
        Cache.put(@live_cache_key, entries)
        entries

      :unavailable ->
        case Cache.get_stale(@live_cache_key) do
          {:ok, stale} -> stale
          :miss -> :unavailable
        end
    end
  end

  defp compute_live_signals do
    client = prometheus_client()

    results =
      Enum.map(@allowlist, fn entry ->
        case client.query(scoped_query(entry.query)) do
          {:ok, value} when is_number(value) -> {:ok, live_entry(entry, value)}
          _ -> :error
        end
      end)

    if Enum.all?(results, &(&1 == :error)) do
      :unavailable
    else
      entries =
        Enum.flat_map(results, fn
          {:ok, entry} -> [entry]
          :error -> []
        end)

      {:ok, entries}
    end
  end

  defp live_entry(entry, value) do
    entry
    |> Map.take(@entry_public_keys)
    |> Map.put(:value, value)
  end

  defp durable_entry(key, value, label, opts) do
    %{
      key: key,
      label: label,
      what: Keyword.fetch!(opts, :what),
      how: Keyword.fetch!(opts, :how),
      why: Keyword.fetch!(opts, :why),
      unit: Keyword.fetch!(opts, :unit),
      value: value
    }
  end

  defp edition_count do
    Repo.one(from(e in BookEdition, select: count(e.id))) || 0
  end

  defp pct_age_gated(0), do: 0.0

  defp pct_age_gated(total_books) do
    age_gated =
      Repo.one(from(b in Book, where: b.visibility_tier == "age_gated", select: count(b.id))) || 0

    Float.round(age_gated / total_books * 100, 1)
  end

  defp current_period_cost_cents do
    Costs.current_period_costs()
    |> Enum.reduce(0, fn c, acc -> acc + c.amount_cents end)
  end

  defp prometheus_client do
    Application.get_env(:core, :transparency_prometheus_client, Stacks.Transparency.Prometheus)
  end

  defp scoped_query(query) when is_binary(query) do
    String.replace(query, "$app", app_label())
  end

  defp app_label do
    Application.get_env(
      :core,
      :fly_metrics_app,
      System.get_env("FLY_APP_NAME") || @default_app
    )
  end
end
