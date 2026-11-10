defmodule Stacks.Costs do
  @moduledoc """
      Context for platform cost transparency.

      Manages infrastructure cost line items stored in `op.platform_costs` and
      computes real usage metrics from the database for consumer-friendly cost
      breakdowns. All data is aggregate platform operational costs — no user
      data is ever stored or exposed through this context.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Core.Repo
  alias Oban.Job
  alias Stacks.Accounts.User
  alias Stacks.AI.GpuWindow
  alias Stacks.Books.{Book, UploadedImage}
  alias Stacks.Costs.PlatformCost

  require Logger

  @fly_core_cents 534
  # always-on support services (Grafana, VictoriaMetrics, SearXNG, scraper):
  # 2× shared-1x/256MB ($1.94) + 2× shared-1x/512MB ($3.19) at the Fly rate card
  @fly_services_cents 1026
  # ⛔ THE SINGLE OWNER OF MODAL'S PRICE. It was declared twice — 3 cents here
  # and 1 cent as `@default_modal_cost_per_call_cents` in `Stacks.AI.Client` —
  # and nothing configured the second, so the budget guard charged 1 cent per
  # inference while this page told readers 3. Two constants for one price is how
  # they drift, and these had already drifted 3×.
  #
  # ⛔ RENAMED, BECAUSE ONE NAME WAS SERVING TWO PURPOSES AND THAT WAS THE BUG.
  #
  # As a PRICE this figure was wrong by 18.9x: measurement puts the warm active
  # cost of an identification at 0.159c (5.2s of A10G at $0.000306/s) and the
  # cold one at 0.734c. ~3c is almost exactly the ALL-IN cost at three
  # inferences per container, which is why it survived — and which means that
  # beside a separate idle line it double-counted the tail. The cost page now
  # prices inference from MEASURED GPU seconds and never reads this.
  #
  # ⚖️ It stays, under an honest name, because the BUDGET CEILING is a
  # different problem with the opposite safe direction. A ceiling that
  # under-charges fails to stop runaway spend; one that over-charges trips
  # early and is merely annoying. So a deliberately conservative per-call
  # estimate is correct there and wrong on a page claiming to say what things
  # cost. ⚠️ Do not reunify these without deciding which direction each caller
  # needs to err in.
  @modal_budget_estimate_cents_per_call 3
  # ⛔ AN ALLOWLIST, NOT A DENYLIST, AND THE POLARITY IS THE WHOLE POINT.
  #
  # The aggregations used to reject `basis == "absent"`. Add a fourth value
  # later — `estimated`, `pending`, `unavailable`, any of which is also not a
  # measurement — and every one would be SILENTLY SUMMED AS MONEY, because the
  # filter only knew the one name. An allowlist fails closed: a new basis is
  # excluded from money until someone deliberately adds it here.
  #
  # ⚖️ For a column whose entire job is to stop a page rendering a number it
  # does not have, the money side is the side that must opt in.
  @bases_that_carry_money ~w(measured rate_card)

  # Modal's published A10 serverless rate: $0.000306/sec, i.e. $1.10/hour,
  # consistent across modal.com/pricing, their notebooks page and their
  # GPU-types article. Held in MICRO-cents per second because $0.000306 is
  # 0.0306 cents — a cents-denominated integer cannot express it, and rounding
  # it to 0 is how a GPU becomes free.
  #
  # ⬛ CONFIRMED BY MODAL'S OWN API, not inferred from a pricing page:
  # `modal billing rates` returns `Nvidia A10G: $1.10 / hour`. That disposes of
  # the caveat this comment used to carry — that a page listing "A10" was being
  # applied to an A10G, from an article fifteen months old.
  #
  # ⚠️ Still a rate card rather than an invoice: it is the published price, and
  # what a reader is charged also depends on seconds nobody here counts. The
  # reconciliation that checks this is `modal billing report`, and on
  # 2026-11-10 it agreed — $0.904 of A10G against ~9.9 implied container
  # lifetimes, matching the sessions driven by hand that day.
  @a10g_micro_cents_per_second 3_060

  @neon_cents 0
  @domain_monthly_cents 100

  @doc """
      Modal's price per inference, in whole cents.

      ⚖️ Exposed so `Stacks.AI.Client` charges the budget at the same rate this
      page bills at. They were separate constants that disagreed by 3×.
  """
  @spec modal_budget_estimate_cents_per_call() :: pos_integer()
  def modal_budget_estimate_cents_per_call, do: @modal_budget_estimate_cents_per_call

  @doc """
      What a GPU inference costs BEYOND the baseline charged for every call.

      ⛔ A BARCODE DECODE AND A 7B VLM INFERENCE ARE NOT THE SAME COST, and
      until the vision response carried a tier they were charged identically.
      A CPU barcode pre-pass answers without waking the model at all; billing
      it at the GPU rate is what made "should a cover-embedding tier exist?"
      unanswerable from this ledger.

      ⚖️ A surcharge rather than a second price, because the baseline is
      already charged before the response is parsed — a request that errored
      still ran the container. This is the difference, not the total.

      ⚠️ Derived from the one price rather than declared separately. Two
      constants for one price is how they drift, and these already had: the
      page billed 3 cents while the budget guard charged 1.
  """
  @spec modal_gpu_inference_surcharge_cents() :: non_neg_integer()
  def modal_gpu_inference_surcharge_cents, do: @modal_budget_estimate_cents_per_call

  @doc """
      Returns all cost line items for the current billing period (current calendar month).
  """
  @spec current_period_costs() :: [PlatformCost.t()]
  def current_period_costs do
    now = DateTime.utc_now()
    period_start = beginning_of_month(now)
    period_end = end_of_month(now)

    PlatformCost
    |> where([c], c.period_start >= ^period_start and c.period_end <= ^period_end)
    |> order_by([c], [c.category, c.service])
    |> Repo.all()
  end

  @doc """
      Returns cost line items grouped by month for the last `months` months.
  """
  @spec monthly_totals(pos_integer()) :: [map()]
  def monthly_totals(months \\ 6) do
    cutoff =
      DateTime.utc_now()
      |> beginning_of_month()
      |> DateTime.add(-months * 31 * 24 * 3600, :second)

    PlatformCost
    |> where([c], c.period_start >= ^cutoff)
    # ⛔ THE HISTORICAL SERIES EXCLUDES THEM AS WELL — the fourth aggregation
    # site, and the only one in SQL rather than in Elixir, which is why it was
    # the easiest to miss. A monthly total that silently includes figures nobody
    # measured is a chart that lies about the past, where nobody will ever
    # re-check it.
    |> where([c], c.basis in ^@bases_that_carry_money)
    |> group_by([c], [c.period_start, c.period_end])
    |> select([c], %{
      period_start: c.period_start,
      period_end: c.period_end,
      total_cents: sum(c.amount_cents)
    })
    |> order_by([c], c.period_start)
    |> Repo.all()
  end

  @doc """
      Returns platform usage metrics derived from actual database contents.
      These power the consumer-friendly cost explanations.
  """
  @spec usage_metrics() :: map()
  def usage_metrics do
    %{
      books: book_count(),
      uploads: upload_count(),
      placements: placement_count(),
      db_size_bytes: db_size_bytes(),
      avg_upload_payload_bytes: avg_upload_payload_bytes(),
      vision_jobs_this_month:
        case vision_jobs_this_month() do
          {:ok, n} -> n
          :error -> 0
        end
    }
  end

  @doc "Total books in the system."
  @spec book_count() :: non_neg_integer()
  def book_count do
    Repo.one(from(b in Book, select: count(b.id))) || 0
  end

  @doc "Total registered users."
  @spec user_count() :: non_neg_integer()
  def user_count do
    Repo.one(from(u in User, select: count(u.id))) || 0
  end

  @doc "Total uploaded images."
  @spec upload_count() :: non_neg_integer()
  def upload_count do
    Repo.one(from(i in UploadedImage, select: count(i.id))) || 0
  end

  @doc """
      Total bookshelf placements, platform-wide.

      ⛔ Answered through `op.platform_row_counts()` rather than by counting the
      table, because counting it directly is wrong twice over. Unscoped it is
      refused outright — `op.bookshelf_placements` is row-level secured and this
      number is published on the PUBLIC transparency page, so the page 500s. And
      under the anonymous scope it succeeds while returning the count of
      publicly-visible placements, which on this database is 0 of 220: a
      plausible smaller number no reader could tell from the truth, on the one
      page whose entire purpose is being trustworthy about figures.
  """
  @spec placement_count() :: non_neg_integer()
  def placement_count do
    case Repo.query("SELECT placements FROM op.platform_row_counts()") do
      {:ok, %{rows: [[count]]}} when is_integer(count) -> count
      other -> log_and_zero(other, "placement_count")
    end
  end

  # ⚠️ Zero is a defensible degraded answer for a cost-breakdown denominator,
  # but ONLY if the failure is visible. A silent zero here is the shape that
  # made the metrics pipeline report a complete system delivering nothing.
  defp log_and_zero(other, what) do
    Logger.warning("Costs.#{what} could not read the platform totals: #{inspect(other)}")
    0
  end

  @doc "Database size in bytes (pg_database_size)."
  @spec db_size_bytes() :: non_neg_integer()
  def db_size_bytes do
    case Repo.query("SELECT pg_database_size(current_database())") do
      {:ok, %{rows: [[size]]}} when is_integer(size) -> size
      _ -> 0
    end
  end

  @doc "Average size of vision job payloads in bytes (proxy for image size)."
  @spec avg_upload_payload_bytes() :: non_neg_integer()
  def avg_upload_payload_bytes do
    result =
      Repo.one(
        from(j in Job,
          where: j.queue == "vision",
          select: fragment("coalesce(avg(octet_length(?::text))::bigint, 0)", j.args)
        )
      )

    result || 0
  end

  @doc """
      Number of Modal vision inferences this month, counted from the per-call
      request metric.

      Not from `oban_jobs`: job rows are pruned, so counting them reports only
      the retention window rather than the month — and this is the figure the
      largest compute line on the public cost page is derived from. ⚠️ The window was sixty
      seconds when this was written and is now seven days; the decision is
      unchanged, because a MONTH-to-date figure cannot be derived from a
      seven-day table either. Raising retention further would not rescue it —
      the counter is the right source, not a longer-lived side effect. Counts the calls Counts the calls
      that reached Modal and returned, which is what Modal bills for; a call
      that raised before a response is counted separately as an exception.
      Returns `:error` when the metric store cannot be reached, which the cost
      item renders as an estimate rather than as zero.
  """
  @spec vision_jobs_this_month() :: {:ok, non_neg_integer()} | :error
  def vision_jobs_this_month do
    metric_count_this_month("stacks_vision_request_stop_duration_milliseconds_count")
  end

  @platform_cost_valid_categories ~w(hosting compute database domain services)
  @platform_cost_valid_bases ~w(measured rate_card absent)

  # The service names this module itself writes — every `service:` literal in
  # the seeding functions below, which is the whole vocabulary the column is
  # ever given by us.
  #
  # ⚠️ This exists because `service` is a FREE-TEXT column. `category` is
  # validated by `validate_inclusion` against the list above, so its label is
  # bounded by code a machine can check; `service` has no such validation, and
  # a label is a cardinality commitment to the metrics store. A new service name
  # minted tomorrow would mint a new time series forever.
  #
  # The ROW keeps whatever it was given — it is the record, and truncating a
  # record to fit a metric would be the wrong trade. Only the LABEL collapses,
  # to "other", which is a visible signal to come and add the name here rather
  # than a silent loss.
  @telemetry_services [
    "Axiom",
    "Brave Search API",
    "Domain Registration",
    "Fly.io Core",
    "Fly.io Services",
    "Google Books & Open Library",
    "Modal GPU Inference",
    # ⚖️ Declared because the counter collapsed it to "other" the moment the
    # line existed — which is this allowlist working as its comment above
    # promises, and the reason a denylist would have been wrong here: a new
    # service would have minted a time series forever before anyone noticed.
    "Modal GPU Idle",
    "Neon PostgreSQL",
    "Resend",
    "Together AI"
  ]

  @doc "The service values the cost counter may label. Anything else labels as `other`."
  @spec telemetry_services() :: [String.t()]
  def telemetry_services, do: @telemetry_services

  # Same shape as the audit writer's bounding, deliberately: one rule, so a
  # reader who has met one has met both. A compile-time guard rather than a
  # runtime membership test, so the allowed set is fixed where it is declared
  # instead of being passed in by the caller it is meant to constrain.
  defp bounded_service(service) when service in @telemetry_services, do: service
  defp bounded_service(_service), do: "other"

  @doc "Changeset for creating or updating a platform cost line item."
  def platform_cost_changeset(cost, attrs) do
    cost
    |> cast(attrs, [
      :category,
      :service,
      :description,
      :amount_cents,
      :currency,
      :period_start,
      :period_end,
      :basis
    ])
    |> validate_required([
      :category,
      :service,
      :amount_cents,
      :currency,
      :period_start,
      :period_end
    ])
    |> validate_inclusion(:category, @platform_cost_valid_categories)
    # ⛔ A closed vocabulary, mirrored by a CHECK below. "absent" is the value
    # the page keys on to render text instead of money, so a typo here would put
    # a $0.00 back on a line that has no figure — the exact defect this column
    # was added to remove.
    |> validate_inclusion(:basis, @platform_cost_valid_bases)
    |> validate_number(:amount_cents, greater_than_or_equal_to: 0)
    |> unique_constraint([:service, :period_start, :period_end])
    # The column now carries the same two rules as a CHECK, because the factory
    # and any future non-changeset writer bypass everything above. These name the
    # constraints so a violation arrives as a changeset error rather than as a
    # raw database error the caller has no clause for.
    |> check_constraint(:category,
      name: :platform_costs_category_known,
      message: "is not a recognised category"
    )
    |> check_constraint(:basis,
      name: :platform_costs_basis_is_known,
      message: "is not a recognised basis"
    )
    |> check_constraint(:amount_cents,
      name: :platform_costs_amount_not_negative,
      message: "must be zero or more"
    )
  end

  @doc """
      Upserts a cost line item. If a record with the same service and period
      already exists, it updates the amount and description.
  """
  @spec upsert_cost(map()) :: {:ok, PlatformCost.t()} | {:error, Ecto.Changeset.t()}
  def upsert_cost(attrs) do
    result =
      %PlatformCost{}
      |> platform_cost_changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:amount_cents, :description, :updated_at]},
        conflict_target: [:service, :period_start, :period_end]
      )

    case result do
      {:ok, cost} ->
        :telemetry.execute(
          [:stacks, :costs, :recorded],
          %{amount_cents: cost.amount_cents},
          %{
            category: cost.category,
            service: bounded_service(cost.service)
          }
        )

      _ ->
        :ok
    end

    result
  end

  @doc """
      Builds the 10 platform cost line items for a billing period — every
      third-party the platform integrates with, free tier or not, so the
      public page accounts for all of them.

      Single source of truth for the platform cost line items, shared by
      `Stacks.Workers.RefreshCostsJob` (which passes live usage counts and
      measured figures via `opts`) and `seed_current_period_costs/0` (which
      passes none, yielding the deterministic flat-estimate set). Each item
      is a map with `:category`, `:service`, `:description`, `:amount_cents`,
      `:period_start`, `:period_end`, and `:currency`.

      The Modal inference item's `amount_cents` is derived from `:gpu_active_seconds`
      at the published A10G rate, NOT from `vision_jobs` — the count only appears in
      the description. Without that measurement the line is `basis: "absent"`,
      because an inference count says nothing about cost once the price is per second.
  """
  @spec build_cost_items(DateTime.t(), DateTime.t(), non_neg_integer() | nil, keyword()) ::
          [map()]
  def build_cost_items(period_start, period_end, vision_jobs, opts \\ []) do
    base = %{period_start: period_start, period_end: period_end, currency: "USD"}

    [
      fly_core_item(base, Keyword.get(opts, :core_awake_seconds)),
      fly_services_item(base, Keyword.get(opts, :fly_services_cents)),
      modal_item(base, vision_jobs, Keyword.get(opts, :gpu_active_seconds)),
      modal_idle_item(base, Keyword.get(opts, :gpu_cold_starts)),
      together_item(base, Keyword.get(opts, :together_completions)),
      neon_item(base, Keyword.get(opts, :neon_cents)),
      resend_item(base, Keyword.get(opts, :emails_sent)),
      brave_item(base, Keyword.get(opts, :brave_searches)),
      metadata_apis_item(base, Keyword.get(opts, :isbn_lookups)),
      Map.merge(base, %{
        category: "services",
        service: "Axiom",
        description: "Log retention via the log shipper — free tier (0.5 TB/month ingest)",
        amount_cents: 0
      }),
      Map.merge(base, %{
        category: "domain",
        service: "Domain Registration",
        description: "#{canonical_domain()} — annual registration amortised monthly",
        amount_cents: @domain_monthly_cents
      })
    ]
  end

  # Modal exposes no billing API, so the inference count is our own measurement.
  # When the metric store cannot be reached we say the figure is unavailable
  # rather than printing "0 inferences", which on a transparency page would read
  # as a claim that nothing ran.
  # ⛔ A SEPARATE LINE, BECAUSE IT IS A SEPARATE COST AND THE OLD LINE SAID SO.
  # The inference line's own description admitted it "counts inference only: a
  # container also bills while idle for up to its scaledown window after the
  # last request, which this figure omits". That omission was the honest thing
  # to write and the wrong thing to leave — a reader cannot weigh a cost they
  # are told exists but never shown.
  defp modal_idle_item(base, nil) do
    Map.merge(base, %{
      category: "compute",
      service: "Modal GPU Idle",
      description:
        "A10G seconds billed while a container was awake but answering nothing — the tail " <>
          "after each container's last request. This month's container count is unavailable, " <>
          "so no charge is shown",
      amount_cents: 0,
      basis: "absent"
    })
  end

  defp modal_idle_item(base, cold_starts) when is_integer(cold_starts) do
    seconds = idle_gpu_seconds(cold_starts)

    # ⚖️ Micro-cents throughout, divided to cents only at the end. At
    # 3,060 micro-cents per second a cents-first calculation rounds every
    # individual second to zero, which is the same class of unit error that
    # left the Modal ceiling needing 50,000,000 calls to trip.
    cents = div(seconds * @a10g_micro_cents_per_second, 100_000)

    Map.merge(base, %{
      category: "compute",
      service: "Modal GPU Idle",
      description:
        "#{cold_starts} GPU container(s) started this month × " <>
          "#{GpuWindow.scaledown_window_s()}s scaledown window = #{seconds}s of " <>
          "idle A10G time at $1.10/hour. This is the cost of a GPU waiting, which the " <>
          "inference line excludes. Published rate, not an invoice. A lower bound: it counts " <>
          "only containers whose first inference returned a response, so one that woke and then " <>
          "failed is not counted here",
      amount_cents: cents,
      basis: "rate_card"
    })
  end

  # ⚖️ The basis follows the MEASUREMENT, not the count. Knowing how many
  # inferences ran says nothing about what they cost once the price is per
  # second — so a month with a known count and no GPU-seconds figure is
  # genuinely unmeasured, and saying `rate_card` over a zero would be the same
  # "$0.00 for something we did not measure" this vocabulary exists to stop.
  defp inference_basis(seconds) when is_number(seconds) and seconds > 0, do: "rate_card"
  defp inference_basis(_), do: "absent"

  defp inference_description(seconds, vision_jobs) when is_number(seconds) and seconds > 0 do
    "Qwen2.5-VL-7B on A10G — #{round(seconds)}s of measured GPU time across #{vision_jobs} " <>
      "inference(s) this month at $1.10/hour. Counts the model's own classify and extract " <>
      "stages only; the sidecar's download and CPU barcode work ran on no GPU, and the idle " <>
      "tail is charged on its own line. Published rate, not an invoice. ⚠️ Measured from " <>
      "responses, so failed requests that still used GPU time are missing; and the timings " <>
      "include queueing inside Modal, which can overstate a busy period"
  end

  defp inference_description(_seconds, vision_jobs) do
    "Qwen2.5-VL-7B on A10G — #{vision_jobs} inference(s) counted this month, but the GPU-time " <>
      "measurement they are priced from is unavailable, so no charge is shown"
  end

  @doc """
  Billed idle GPU seconds implied by a count of container cold starts.

  ⛔ **The idle tail is the cost nothing was measuring.** A container bills
  from the moment it wakes until its scaledown window expires after the last
  request, and the container age on a response is sampled only when a request
  runs — so the idle seconds are precisely the ones no observation covers.
  Counting cold starts counts container lifetimes, which is the unit the tail
  is billed per.

  ⚠️ **The dominant term, not the whole figure.** It omits the seconds a
  container spent actually answering, which the inference line charges
  separately — so the two lines together are the estimate and neither is
  double-counting the other. `GpuWindow` holds the exact
  per-container model; this is what the metrics store can carry without an
  unbounded container-id label.
  """
  def idle_gpu_seconds(cold_starts) when is_integer(cold_starts) and cold_starts >= 0 do
    cold_starts * GpuWindow.scaledown_window_s()
  end

  @doc "Micro-cents per GPU-second at the published A10 rate."
  def a10g_micro_cents_per_second, do: @a10g_micro_cents_per_second

  defp modal_item(base, nil, _gpu_active_seconds) do
    Map.merge(base, %{
      category: "compute",
      service: "Modal GPU Inference",
      description:
        "Qwen2.5-VL-7B on A10G (~$0.03/inference; Modal exposes no billing API, " <>
          "so this is our own count) — this month's inference count is " <>
          "temporarily unavailable, so no charge is shown",
      amount_cents: 0,
      basis: "absent"
    })
  end

  # ⛔ CHARGED ON MEASURED GPU SECONDS, NOT A FLAT RATE THAT WAS 18.9x WRONG.
  #
  # This read `vision_jobs * 3` cents. Measurement puts the warm active cost of
  # an identification at 0.159c (5.2s x $0.000306) and the cold one at 0.734c,
  # so 3c was 19x and 4x those. It was never an active rate: ~3c is almost
  # exactly the ALL-IN cost at three inferences per container, which is why it
  # looked right — and which means that once the idle tail got its own line,
  # this one DOUBLE-COUNTED it.
  #
  # ⚖️ Both lines now derive from `@a10g_micro_cents_per_second`, so there is
  # one price in the system instead of two that disagreed by a factor of 19.
  defp modal_item(base, vision_jobs, gpu_active_seconds) when is_integer(vision_jobs) do
    cents =
      case gpu_active_seconds do
        s when is_number(s) and s > 0 ->
          div(round(s) * @a10g_micro_cents_per_second, 100_000)

        _ ->
          0
      end

    Map.merge(base, %{
      category: "compute",
      service: "Modal GPU Inference",
      description: inference_description(gpu_active_seconds, vision_jobs),
      amount_cents: cents,
      basis: inference_basis(gpu_active_seconds)
    })
  end

  # Together bills per token with no billing API; we count our own successful
  # completions (short prompts, ≤1k tokens) and price them at published
  # Llama 3.3 70B Turbo rates — ~$0.001 per completion, i.e. 0.1¢ each.
  defp together_item(base, nil) do
    Map.merge(base, %{
      category: "compute",
      service: "Together AI",
      description:
        "Llama 3.3 70B for source vetting, post-book linking, review summaries — " <>
          "usage counted daily from our own metrics",
      amount_cents: 0,
      basis: "absent"
    })
  end

  defp together_item(base, completions) when is_integer(completions) do
    Map.merge(base, %{
      category: "compute",
      service: "Together AI",
      description:
        "Llama 3.3 70B for source vetting, post-book linking, review summaries — " <>
          "#{completions} completions this month (~$0.001/each at published token " <>
          "rates; no billing API, so this is our own count)",
      amount_cents: round(completions * 0.1),
      basis: "rate_card"
    })
  end

  # Resend free tier: 3,000 emails/month; beyond it the $20/month plan applies.
  defp resend_item(base, nil) do
    Map.merge(base, %{
      category: "services",
      service: "Resend",
      description:
        "Transactional email (confirmations, invites) — usage counted daily " <>
          "against the 3,000/month free tier",
      amount_cents: 0,
      basis: "absent"
    })
  end

  defp resend_item(base, sends) when is_integer(sends) do
    over = sends > 3000

    Map.merge(base, %{
      category: "services",
      service: "Resend",
      description:
        "Transactional email (confirmations, invites) — #{sends} of 3,000 " <>
          "free-tier sends this month" <>
          if(over, do: " (over the allowance: requires the $20/month plan)", else: ""),
      amount_cents: if(over, do: 2000, else: 0),
      basis: "rate_card"
    })
  end

  # Brave free tier: 2,000 queries/month; overage priced at the Base plan's
  # $3 per 1,000 queries (0.3¢ each).
  defp brave_item(base, nil) do
    Map.merge(base, %{
      category: "services",
      service: "Brave Search API",
      description:
        "Author/bookshop source discovery — usage counted daily against the " <>
          "2,000/month free tier",
      amount_cents: 0,
      basis: "absent"
    })
  end

  defp brave_item(base, searches) when is_integer(searches) do
    overage = max(searches - 2000, 0)

    Map.merge(base, %{
      category: "services",
      service: "Brave Search API",
      description:
        "Author/bookshop source discovery — #{searches} of 2,000 free-tier " <>
          "queries this month" <>
          if(overage > 0, do: " (#{overage} over, at $3 per 1,000)", else: ""),
      amount_cents: round(overage * 0.3),
      basis: "rate_card"
    })
  end

  # Google Books and Open Library are free at any volume — the line exists so
  # the dependency is accounted for, with the real call volume shown.
  defp metadata_apis_item(base, nil) do
    Map.merge(base, %{
      category: "services",
      service: "Google Books & Open Library",
      description: "ISBN verification for every book entering the system — free at any volume",
      amount_cents: 0,
      basis: "absent"
    })
  end

  defp metadata_apis_item(base, lookups) when is_integer(lookups) do
    Map.merge(base, %{
      category: "services",
      service: "Google Books & Open Library",
      description:
        "ISBN verification for every book entering the system — #{lookups} " <>
          "lookups this month; both APIs are free at any volume",
      amount_cents: 0,
      basis: "rate_card"
    })
  end

  # Fly bills started-machine-seconds. The core app pushes metrics every
  # ~15s while awake, so its own series in VictoriaMetrics measure exactly
  # the thing Fly meters — no billing API, no extra credentials. With no
  # measurement (preview seeds, metrics store unreachable) the line falls
  # back to the flat full-time estimate and says so.
  @fly_full_month_seconds 730 * 3600

  defp fly_core_item(base, nil) do
    Map.merge(base, %{
      category: "hosting",
      service: "Fly.io Core",
      description: "Phoenix API + Elm SPA (shared-cpu-1x, 512MB, IAD) — estimated flat-rate",
      amount_cents: @fly_core_cents,
      basis: "rate_card"
    })
  end

  defp fly_core_item(base, awake_seconds) when is_integer(awake_seconds) do
    hours = Float.round(awake_seconds / 3600, 1)
    cents = round(@fly_core_cents * awake_seconds / @fly_full_month_seconds)

    Map.merge(base, %{
      category: "hosting",
      service: "Fly.io Core",
      description:
        "Phoenix API + Elm SPA (shared-cpu-1x, 512MB, IAD) — measured: " <>
          "awake #{hours}h this period (scales to zero when idle)",
      amount_cents: cents,
      basis: "rate_card"
    })
  end

  # The rest of the Fly account: every machine and volume that is not the
  # scale-to-zero core app — always-on support services, plus any preview
  # stacks still running. Measured figures come from the billing gauges a
  # scheduled workflow computes from the Fly machine inventory × rate card
  # and pushes into VictoriaMetrics; without them, a flat rate-card estimate
  # of the four always-on prod services.
  defp fly_services_item(base, nil) do
    Map.merge(base, %{
      category: "hosting",
      service: "Fly.io Services",
      description:
        "Always-on support services (Grafana, metrics store, search, scraper) — " <>
          "estimated flat-rate",
      amount_cents: @fly_services_cents,
      basis: "rate_card"
    })
  end

  defp fly_services_item(base, cents) when is_integer(cents) do
    Map.merge(base, %{
      category: "hosting",
      service: "Fly.io Services",
      description:
        "All non-core machines and volumes on the account (support services + " <>
          "any running preview stacks) — measured from the live machine inventory " <>
          "at Fly's rate card",
      amount_cents: cents,
      basis: "measured"
    })
  end

  defp neon_item(base, nil) do
    Map.merge(base, %{
      category: "database",
      service: "Neon PostgreSQL",
      description: "Serverless Postgres (free tier: 0.5 GiB, 190 compute hours)",
      amount_cents: @neon_cents,
      basis: "rate_card"
    })
  end

  defp neon_item(base, cents) when is_integer(cents) do
    Map.merge(base, %{
      category: "database",
      service: "Neon PostgreSQL",
      description:
        "Serverless Postgres — measured from Neon's own consumption API " <>
          "(all projects, compute + storage vs plan allowance)",
      amount_cents: cents,
      basis: "measured"
    })
  end

  @doc """
      Measured awake-seconds of the core app this period, from its own pushed
      metrics: samples of one always-emitted series counted over the window,
      times the push interval. `:error` when the metrics store is unreachable
      or holds no samples — callers fall back to the flat estimate.
  """
  @spec core_awake_seconds(DateTime.t(), DateTime.t()) :: {:ok, non_neg_integer()} | :error
  def core_awake_seconds(%DateTime{} = period_start, %DateTime{} = now) do
    window_s = max(DateTime.diff(now, period_start, :second), 1)
    interval_s = div(Application.get_env(:core, :metrics_push_interval_ms, 15_000), 1000)
    app = System.get_env("FLY_APP_NAME") || "thestacks-core"

    # sum across series: each running machine pushes its own series, and Fly
    # bills per started machine, so total samples ≈ machine-seconds / interval
    query =
      ~s|sum(count_over_time(stacks_fuse_state_state{app="#{app}",fuse_name="vision_fuse"}[#{window_s}s]))|

    case prometheus_client().query(query) do
      {:ok, samples} when is_number(samples) and samples > 0 ->
        {:ok, round(samples * interval_s)}

      _ ->
        :error
    end
  end

  @doc """
      Month-to-date cents for a provider from the billing gauges a scheduled
      workflow computes (Fly machine inventory × rate card, Neon consumption
      API) and pushes into VictoriaMetrics daily. The 48h lookback tolerates a
      missed run; beyond that (or with no gauge at all) returns `:error` and
      callers fall back to the flat estimates.
  """
  @spec billing_gauge_cents(String.t()) :: {:ok, non_neg_integer()} | :error
  def billing_gauge_cents(provider) when provider in ["fly", "neon"] do
    query = ~s|sum(last_over_time(stacks_billing_mtd_cents{provider="#{provider}"}[48h]))|

    case prometheus_client().query(query) do
      {:ok, cents} when is_number(cents) and cents >= 0 -> {:ok, round(cents)}
      _ -> :error
    end
  end

  @doc """
      Month-to-date increase of a counter family from the metrics store —
      the usage-count source for third-party lines (Together completions,
      Brave queries, ISBN lookups). `increase` over the elapsed month
      tolerates per-boot counter resets. `:error` when the store is
      unreachable; a family with no samples yet counts as 0.
  """
  @spec metric_count_this_month(String.t()) :: {:ok, non_neg_integer()} | :error
  def metric_count_this_month(family) do
    now = DateTime.utc_now()
    window_s = max(DateTime.diff(now, beginning_of_month(now), :second), 1)
    app = System.get_env("FLY_APP_NAME") || "thestacks-core"

    query = ~s|sum(increase(#{family}{app="#{app}"}[#{window_s}s]))|

    case prometheus_client().query(query) do
      {:ok, count} when is_number(count) and count >= 0 ->
        {:ok, round(count)}

      # ⛔ `:no_data` IS NOT ZERO, AND MAPPING IT TO ZERO DEFEATED A RULE THIS
      # CODEBASE HAD ALREADY WRITTEN DOWN ONE LAYER DOWN.
      #
      # `RefreshCostsJob`'s `unwrap/1` says it outright — "a measurement we
      # could not take is `nil`, never 0 … because a transparency page printing
      # '0' would be claiming the service went unused" — and every cost item has
      # a nil clause for exactly that. But this function converted the
      # unavailable signal into a real `{:ok, 0}` BEFORE that unwrap could see
      # it, so the nil clause was unreachable and the page printed `$0.00` for a
      # family with no samples, under the heading "Every number on this page is
      # real".
      #
      # ⚖️ A family with no samples and a store that errored are both "no figure
      # for this period", and both must reach the caller's nil path. They are
      # distinguishable here if a future caller needs to tell them apart; what
      # is not acceptable is either one arriving as a number.
      {:error, :no_data} ->
        :error

      _ ->
        :error
    end
  end

  @doc """
      Emails handed to Resend this month, counted from the delivery counter.

      Not from `oban_jobs`: job rows are pruned, so counting them reports only
      the retention window rather than the month — and this is the figure the
      free-tier email line on the public cost page is derived from. ⚠️ The window was sixty
      seconds when this was written and is now seven days; the decision is
      unchanged, because a MONTH-to-date figure cannot be derived from a
      seven-day table either. Raising retention further would not rescue it —
      the counter is the right source, not a longer-lived side effect. Returns `:error` when the
      metric store cannot be reached, which the cost item renders as the
      free-tier line without a count rather than as zero.
  """
  @spec emails_this_month() :: {:ok, non_neg_integer()} | :error
  def emails_this_month do
    metric_count_this_month("stacks_email_delivered_count_total")
  end

  defp canonical_domain do
    Application.get_env(:core, :canonical_domain, "readinginthestacks.com")
  end

  defp prometheus_client do
    Application.get_env(:core, :transparency_prometheus_client, Stacks.Transparency.Prometheus)
  end

  @doc """
      Seeds the 10 static current-month cost line items so fresh previews have
      data before the daily `RefreshCostsJob` cron (06:00) first fires. Reuses
      `build_cost_items/4` with Modal fixed at 0 inferences (1660 cents total)
      — the same list the cron produces, so seed and cron cannot diverge — and
      the same period window + conflict target, so the cron updates these rows
      in place. Idempotent; returns `:ok`.
  """
  @spec seed_current_period_costs() :: :ok
  def seed_current_period_costs do
    now = DateTime.utc_now()
    period_start = beginning_of_month(now)
    period_end = end_of_month(now)

    period_start
    |> build_cost_items(period_end, 0)
    |> Enum.each(&upsert_cost/1)

    :ok
  end

  @doc """
      Builds the full public cost breakdown response with real usage metrics.
      No user data is included — only aggregate platform stats.
  """
  @spec cost_breakdown() :: map()
  def cost_breakdown do
    costs = current_period_costs()
    totals = monthly_totals()
    metrics = usage_metrics()

    # ⛔ THE HEADLINE TOTAL EXCLUDES ABSENT LINES TOO, and this was the third of
    # four aggregation sites — fixed only after a reviewer re-drove the diff.
    #
    # The per-line fix landed, then the category total, and these two were still
    # summing figures nobody has: `total_cents` and the `cost_per_book` derived
    # from it are the FIRST numbers a reader sees, above everything already
    # corrected below.
    #
    # ⚠️ All four sites were correct in production for one reason only: every
    # absent row happens to carry `amount_cents: 0`, so summing it changed
    # nothing. That is the coincidence this issue exists to remove — the moment
    # a builder emits a non-zero amount beside an absent basis, these
    # over-count silently. Relying on it is relying on the defect.
    current_total =
      costs
      |> Enum.filter(&(&1.basis in @bases_that_carry_money))
      |> Enum.reduce(0, fn c, acc -> acc + c.amount_cents end)

    cost_per_book =
      if metrics.books > 0,
        do: Float.round(current_total / metrics.books / 100, 2),
        else: 0.0

    by_category =
      costs
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {category, items} ->
        # ⛔ AN ABSENT LINE IS NOT SUMMED, AND THE COUNT OF THEM IS REPORTED.
        #
        # This used to reduce over every item's `amount_cents`, including lines
        # whose basis is "absent" — where the amount is a placeholder the basis
        # exists to say must not be rendered as money. So the per-line fix
        # landed and the CATEGORY HEADER still printed a dollar figure that
        # silently included figures nobody had: on a live stack, "Compute
        # $0.00" over a Modal line and an unmeasured Together AI one.
        #
        # ⚖️ A reader who never scrolls past the header saw exactly the lie this
        # issue exists to remove. Fixing the leaf and leaving the aggregate is
        # not a partial fix; it is the same defect at the altitude most people
        # read.
        #
        # `unmeasured_count` rather than a nullable total, because a category
        # with two measured lines and one absent one DOES have a defensible
        # subtotal — it is just incomplete, and saying so is more useful than
        # withholding it.
        %{
          category: category,
          total_cents:
            items
            |> Enum.filter(&(&1.basis in @bases_that_carry_money))
            |> Enum.reduce(0, fn c, acc -> acc + c.amount_cents end),
          # ⚖️ THE COMPLEMENT OF THE ALLOWLIST, not `== "absent"`. Counting the
          # one known name would desynchronise the moment a fourth basis
          # arrives: the total (an allowlist) would correctly exclude a
          # `pending` line while this count ignored it, so the header would
          # print a figure that silently omits money with no note saying so.
          # Deriving both from one list makes them consistent by construction.
          unmeasured_count: Enum.count(items, &(&1.basis not in @bases_that_carry_money)),
          items: Enum.map(items, &serialize_cost/1)
        }
      end)
      |> Enum.sort_by(& &1.total_cents, :desc)

    %{
      total_cents: current_total,
      currency: "USD",
      cost_per_book: cost_per_book,
      categories: by_category,
      metrics: metrics,
      monthly_totals: Enum.map(totals, &serialize_monthly_total/1),
      generated_at: DateTime.utc_now()
    }
  end

  defp serialize_cost(%PlatformCost{} = cost) do
    %{
      service: cost.service,
      description: cost.description,
      amount_cents: cost.amount_cents,
      basis: cost.basis,
      refreshed_at: refreshed_at(cost)
    }
  end

  # ⚖️ `updated_at`, not `created_at`: the reader's question is "how fresh is
  # this number", and the row is upserted on each refresh. Empty rather than a
  # timestamp when there is no figure, because there is no refresh to report —
  # a date beside "not yet measured" would imply the absence was measured then.
  defp refreshed_at(%PlatformCost{basis: "absent"}), do: ""
  defp refreshed_at(%PlatformCost{updated_at: nil}), do: ""
  defp refreshed_at(%PlatformCost{} = cost), do: DateTime.to_iso8601(cost.updated_at)

  defp serialize_monthly_total(%{} = total) do
    %{
      period_start: DateTime.to_iso8601(total.period_start),
      period_end: DateTime.to_iso8601(total.period_end),
      total_cents: total.total_cents
    }
  end

  defp beginning_of_month(%DateTime{} = dt) do
    %{dt | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
  end

  defp end_of_month(%DateTime{} = dt) do
    days = Calendar.ISO.days_in_month(dt.year, dt.month)
    %{dt | day: days, hour: 23, minute: 59, second: 59, microsecond: {999_999, 6}}
  end
end
