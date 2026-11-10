defmodule Stacks.CostsTest do
  @moduledoc "Tests for the Stacks.Costs context."

  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Costs
  alias Stacks.Costs.PlatformCost

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = "test-#{inspect(make_ref())}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp collect_costs_events(n) do
    for _ <- 1..n do
      assert_receive {:telemetry_event, [:stacks, :costs, :recorded], measurements, metadata}, 500
      {measurements, metadata}
    end
  end

  describe "upsert_cost/1" do
    test "inserts a new cost line item" do
      now = DateTime.utc_now()

      attrs = %{
        category: "hosting",
        service: "Fly.io Core",
        description: "Phoenix API server",
        amount_cents: 534,
        currency: "USD",
        period_start: %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}},
        period_end: %{now | day: 28, hour: 23, minute: 59, second: 59, microsecond: {999_999, 6}}
      }

      assert {:ok, %PlatformCost{} = cost} = Costs.upsert_cost(attrs)
      assert cost.category == "hosting"
      assert cost.service == "Fly.io Core"
      assert cost.amount_cents == 534
    end

    test "upserts on conflict — updates amount for same service and period" do
      now = DateTime.utc_now()
      period_start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
      period_end = %{now | day: 28, hour: 23, minute: 59, second: 59, microsecond: {999_999, 6}}

      attrs = %{
        category: "hosting",
        service: "Fly.io Core",
        description: "Original",
        amount_cents: 500,
        currency: "USD",
        period_start: period_start,
        period_end: period_end
      }

      assert {:ok, _} = Costs.upsert_cost(attrs)

      updated_attrs = %{attrs | amount_cents: 600, description: "Updated"}
      assert {:ok, %PlatformCost{} = cost} = Costs.upsert_cost(updated_attrs)
      assert cost.amount_cents == 600
    end

    test "rejects invalid category" do
      now = DateTime.utc_now()

      attrs = %{
        category: "invalid_category",
        service: "Test",
        amount_cents: 100,
        currency: "USD",
        period_start: now,
        period_end: now
      }

      assert {:error, changeset} = Costs.upsert_cost(attrs)
      assert %{category: _} = errors_on(changeset)
    end

    test "rejects negative amount" do
      now = DateTime.utc_now()

      attrs = %{
        category: "hosting",
        service: "Test",
        amount_cents: -100,
        currency: "USD",
        period_start: now,
        period_end: now
      }

      assert {:error, changeset} = Costs.upsert_cost(attrs)
      assert %{amount_cents: _} = errors_on(changeset)
    end
  end

  describe "current_period_costs/0" do
    test "returns costs for the current month" do
      now = DateTime.utc_now()
      period_start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
      days = Calendar.ISO.days_in_month(now.year, now.month)

      period_end = %{
        now
        | day: days,
          hour: 23,
          minute: 59,
          second: 59,
          microsecond: {999_999, 6}
      }

      {:ok, _} =
        Costs.upsert_cost(%{
          category: "hosting",
          service: "Test Service",
          amount_cents: 100,
          currency: "USD",
          period_start: period_start,
          period_end: period_end
        })

      costs = Costs.current_period_costs()
      assert costs != []
      assert Enum.any?(costs, &(&1.service == "Test Service"))
    end

    test "returns empty list when no costs exist" do
      assert Costs.current_period_costs() == []
    end
  end

  describe "cost_breakdown/0" do
    test "returns a complete breakdown map with categories and metrics" do
      now = DateTime.utc_now()
      period_start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
      days = Calendar.ISO.days_in_month(now.year, now.month)

      period_end = %{
        now
        | day: days,
          hour: 23,
          minute: 59,
          second: 59,
          microsecond: {999_999, 6}
      }

      {:ok, _} =
        Costs.upsert_cost(%{
          category: "hosting",
          service: "Test",
          amount_cents: 500,
          currency: "USD",
          period_start: period_start,
          period_end: period_end
        })

      breakdown = Costs.cost_breakdown()
      assert is_list(breakdown.categories)
      assert breakdown.total_cents == 500
      assert breakdown.currency == "USD"
      assert is_float(breakdown.cost_per_book)
      assert is_map(breakdown.metrics)
      assert is_integer(breakdown.metrics.books)
      assert is_list(breakdown.monthly_totals)
      assert %DateTime{} = breakdown.generated_at
    end

    test "returns zero cost_per_book when no books exist" do
      breakdown = Costs.cost_breakdown()
      assert breakdown.cost_per_book == 0.0
      assert breakdown.metrics.books == 0
    end
  end

  describe "usage_metrics/0" do
    test "returns aggregate platform metrics without user data" do
      metrics = Costs.usage_metrics()
      assert is_integer(metrics.books)
      assert is_integer(metrics.uploads)
      assert is_integer(metrics.placements)
      assert is_integer(metrics.db_size_bytes)
      assert is_integer(metrics.avg_upload_payload_bytes)
      assert is_integer(metrics.vision_jobs_this_month)
      refute Map.has_key?(metrics, :users)
    end
  end

  describe "book_count/0" do
    test "returns 0 when no books exist" do
      assert Costs.book_count() == 0
    end
  end

  describe "build_cost_items/4" do
    setup do
      now = DateTime.utc_now()
      period_start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
      days = Calendar.ISO.days_in_month(now.year, now.month)

      period_end = %{
        now
        | day: days,
          hour: 23,
          minute: 59,
          second: 59,
          microsecond: {999_999, 6}
      }

      %{period_start: period_start, period_end: period_end}
    end

    test "with vision_jobs 0 yields the 11 seeded line items summing to 1660", ctx do
      items = Costs.build_cost_items(ctx.period_start, ctx.period_end, 0)

      # ⚖️ Asserted by SERVICE NAME as well as by length. A bare count told me
      # nothing about WHICH line had appeared when this went from 10 to 11, and
      # a count is equally satisfied by a line being added and an unrelated one
      # being dropped in the same change.
      assert Enum.map(items, & &1.service) |> Enum.take(5) == [
               "Fly.io Core",
               "Fly.io Services",
               "Modal GPU Inference",
               "Modal GPU Idle",
               "Together AI"
             ]

      assert length(items) == 11

      assert Enum.map(items, & &1.category) ==
               ~w(hosting hosting compute compute compute database services services services services domain)

      assert Enum.map(items, & &1.amount_cents) == [534, 1026, 0, 0, 0, 0, 0, 0, 0, 0, 100]
      assert Enum.reduce(items, 0, fn i, acc -> acc + i.amount_cents end) == 1660

      for item <- items do
        assert item.period_start == ctx.period_start
        assert item.period_end == ctx.period_end
        assert item.currency == "USD"
      end

      modal = Enum.find(items, &(&1.service == "Modal GPU Inference"))
      assert modal.amount_cents == 0
      assert modal.description =~ "0 inference(s) counted this month"
    end

    # ⛔ THE COUNT NO LONGER SETS THE PRICE, AND THIS TEST USED TO ENFORCE THAT
    # IT DID. It read `7 inferences × 3 cents == 21`, and that 3-cent constant
    # is 18.9x the measured warm cost of an identification (0.159c for 5.2s of
    # A10G at $0.000306/s) and 4.1x the cold one. It was really an ALL-IN
    # figure — ~3c is almost exactly the cost at three inferences per container
    # — so charging it beside a separate idle line double-counted the tail.
    #
    # ⚖️ So the count is now only narrative and the GPU SECONDS set the price.
    # 600s at 3,060 micro-cents per second is 1,836,000 micro-cents = 18 cents
    # ($0.1836, i.e. 600s of A10G at $1.10/hour), written out rather than
    # derived from the constant the code reads.
    #
    # ⚠️ MY FIRST VERSION OF THIS LITERAL SAID 183, off by 10x from a slipped
    # digit in 1,836,000. The test failed and the code was right — which is the
    # whole argument for writing the figure out: an expectation derived from
    # `@a10g_micro_cents_per_second` would have agreed with the code silently,
    # and agreed just as happily if the code had been the one that was wrong.
    test "the Modal inference line is priced from measured GPU seconds, not the count", ctx do
      items =
        Costs.build_cost_items(ctx.period_start, ctx.period_end, 7, gpu_active_seconds: 600)

      modal = Enum.find(items, &(&1.service == "Modal GPU Inference"))

      assert modal.amount_cents == 18
      assert modal.basis == "rate_card"
      assert modal.description =~ "600s of measured GPU time across 7 inference(s)"
    end

    # ⬛ ANTI-VACUITY for the pair above: the count must NOT move the figure.
    # If it did, the flat rate would still be in here somewhere.
    test "changing the inference count alone does not change the charge", ctx do
      few = Costs.build_cost_items(ctx.period_start, ctx.period_end, 1, gpu_active_seconds: 600)

      many =
        Costs.build_cost_items(ctx.period_start, ctx.period_end, 900, gpu_active_seconds: 600)

      a = Enum.find(few, &(&1.service == "Modal GPU Inference")).amount_cents
      b = Enum.find(many, &(&1.service == "Modal GPU Inference")).amount_cents

      assert a == b,
             "the inference count moved the charge (#{a} vs #{b}), so a per-inference rate is " <>
               "still in play — and beside the separate idle line that double-counts the tail"
    end

    # ⛔ A LINE MUST NOT CLAIM BOTH "FREE AT ANY VOLUME" AND "NOT YET MEASURED".
    # A ux reviewer read that contradiction straight off the page: the metadata
    # APIs clause carried `basis: "absent"` while its own description said the
    # service is free at any volume. If that is true the cost is a KNOWN zero
    # and no measurement could change it — so the absence was about the lookup
    # count, which is narrative, not about the figure.
    test "a service that is free at any volume reports a known zero, not an absence", ctx do
      items = Costs.build_cost_items(ctx.period_start, ctx.period_end, 0)

      metadata = Enum.find(items, &(&1.service == "Google Books & Open Library"))

      assert metadata.amount_cents == 0

      assert metadata.basis == "rate_card",
             "a published rate of zero needs no quantity, so this is a measured-at-zero line; " <>
               "marking it absent makes the page say \"not yet measured\" beside \"free at any " <>
               "volume\", which cannot both inform a reader"
    end

    # ⬛ ANTI-VACUITY for the pair: the GPU line, whose price is NOT zero, must
    # still go absent without its measurement. If both went rate_card the basis
    # would have stopped describing anything.
    # ⚠️ A counted month with no GPU-time measurement is ABSENT, not zero.
    # Knowing how many inferences ran says nothing about cost once the price is
    # per second, and rendering "$0.00" over a month that definitely used a GPU
    # is the exact defect the basis vocabulary was added to remove.
    test "a counted month with no GPU measurement is absent, not a free month", ctx do
      items = Costs.build_cost_items(ctx.period_start, ctx.period_end, 7)

      modal = Enum.find(items, &(&1.service == "Modal GPU Inference"))

      assert modal.basis == "absent"
      assert modal.description =~ "measurement they are priced from is unavailable"
    end

    test "without a measurement the Fly core line is the flat estimate and says so", ctx do
      items = Costs.build_cost_items(ctx.period_start, ctx.period_end, 0, core_awake_seconds: nil)

      core = Enum.find(items, &(&1.service == "Fly.io Core"))
      assert core.amount_cents == 534
      assert core.description =~ "estimated flat-rate"
    end

    test "with measured awake seconds the Fly core line is proportional to awake time", ctx do
      # 42_120s awake = 11.7h; 534¢ × 42_120 / (730h × 3600) rounds to 9¢
      items =
        Costs.build_cost_items(ctx.period_start, ctx.period_end, 0, core_awake_seconds: 42_120)

      core = Enum.find(items, &(&1.service == "Fly.io Core"))
      assert core.amount_cents == 9
      assert core.description =~ "measured: awake 11.7h this period"
      refute core.description =~ "estimated flat-rate"
    end

    test "a full month awake measures back to the flat monthly rate", ctx do
      items =
        Costs.build_cost_items(ctx.period_start, ctx.period_end, 0,
          core_awake_seconds: 730 * 3600
        )

      core = Enum.find(items, &(&1.service == "Fly.io Core"))
      assert core.amount_cents == 534
    end

    test "third-party usage counts price their lines and land in descriptions", ctx do
      items =
        Costs.build_cost_items(ctx.period_start, ctx.period_end, 0,
          together_completions: 250,
          brave_searches: 2500,
          emails_sent: 42,
          isbn_lookups: 87
        )

      together = Enum.find(items, &(&1.service == "Together AI"))
      assert together.amount_cents == 25
      assert together.description =~ "250 completions this month"

      brave = Enum.find(items, &(&1.service == "Brave Search API"))
      assert brave.amount_cents == 150
      assert brave.description =~ "2500 of 2,000 free-tier"
      assert brave.description =~ "500 over"

      resend = Enum.find(items, &(&1.service == "Resend"))
      assert resend.amount_cents == 0
      assert resend.description =~ "42 of 3,000 free-tier sends"

      metadata = Enum.find(items, &(&1.service == "Google Books & Open Library"))
      assert metadata.amount_cents == 0
      assert metadata.description =~ "87 lookups this month"
    end

    test "usage within every free tier stays at zero cents", ctx do
      items =
        Costs.build_cost_items(ctx.period_start, ctx.period_end, 0,
          together_completions: 0,
          brave_searches: 1999,
          emails_sent: 3000,
          isbn_lookups: 0
        )

      for service <- ["Together AI", "Brave Search API", "Resend", "Axiom"] do
        item = Enum.find(items, &(&1.service == service))
        assert item.amount_cents == 0, "#{service} should be free at this volume"
      end
    end

    test "usage over the resend free tier prices the paid plan", ctx do
      items = Costs.build_cost_items(ctx.period_start, ctx.period_end, 0, emails_sent: 3001)

      resend = Enum.find(items, &(&1.service == "Resend"))
      assert resend.amount_cents == 2000
      assert resend.description =~ "requires the $20/month plan"
    end
  end

  describe "metric_count_this_month/1" do
    alias Stacks.Transparency.MockPrometheusClient

    setup do
      MockPrometheusClient.reset()
      :ok
    end

    test "rounds the month-to-date increase of the family" do
      MockPrometheusClient.put_response({:ok, 42.7})

      assert {:ok, 43} =
               Costs.metric_count_this_month("stacks_discovery_brave_search_count_total")

      query = MockPrometheusClient.last_query()
      assert query =~ "sum(increase(stacks_discovery_brave_search_count_total{"
    end

    # ⛔ REVERSED DELIBERATELY. This test used to assert `{:ok, 0}` for a family
    # with no samples, which PINNED THE DEFECT AS A REQUIREMENT — the same shape
    # as the test that encoded a cents/micro-cent confusion elsewhere in this
    # wave, where a test agreeing with the code proved nothing about either.
    #
    # ⚖️ Its own title was the argument against it: "counts as zero, not an
    # error" treats those as the only two options, when the real answer is a
    # third — no figure for this period. `RefreshCostsJob`'s `unwrap/1` already
    # said so ("a measurement we could not take is `nil`, never 0 … a
    # transparency page printing '0' would be claiming the service went
    # unused"), and every cost item already had a nil clause for it. Mapping
    # `:no_data` to `{:ok, 0}` here made that clause unreachable.
    #
    # ⬛ THE PROBE, quoted as this issue requires: restoring
    # `{:error, :no_data} -> {:ok, 0}` in `metric_count_this_month/1` reds this
    # case with `Expected truthy, got false` on the `:error` match — so the
    # reversal is load-bearing rather than a relabelling.
    test "a family with no samples is no figure, not a zero" do
      MockPrometheusClient.put_response({:error, :no_data})

      assert :error = Costs.metric_count_this_month("stacks_ai_together_completion_count_total"),
             "a family with no samples returned a NUMBER — the caller's nil clause is then " <>
               "unreachable and the transparency page prints $0.00 for a service it has no " <>
               "measurement of"
    end

    # ⬛ ANTI-VACUITY: a real measurement must still come back as a number, or a
    # function that returned `:error` for everything would satisfy the case
    # above and silently blank the whole page.
    test "a family with samples still returns its count" do
      MockPrometheusClient.put_response({:ok, 42})

      assert {:ok, 42} =
               Costs.metric_count_this_month("stacks_ai_together_completion_count_total")
    end

    # ⚖️ AND A GENUINE ZERO IS STILL A ZERO — the store answering "0 samples"
    # is a measurement, and conflating it with "no data" would be the same
    # error pointed the other way.
    test "a measured zero is reported as zero" do
      MockPrometheusClient.put_response({:ok, 0})

      assert {:ok, 0} =
               Costs.metric_count_this_month("stacks_ai_together_completion_count_total")
    end

    test "an unreachable store is an error so callers fall back" do
      MockPrometheusClient.put_response({:error, :nxdomain})

      assert :error = Costs.metric_count_this_month("stacks_ai_together_completion_count_total")
    end
  end

  describe "core_awake_seconds/2" do
    alias Stacks.Transparency.MockPrometheusClient

    setup do
      MockPrometheusClient.reset()
      period_start = ~U[2026-08-01 00:00:00.000000Z]
      now = ~U[2026-08-13 12:00:00.000000Z]
      %{period_start: period_start, now: now}
    end

    test "multiplies the sample count by the push interval", ctx do
      MockPrometheusClient.put_response({:ok, 2799.0})

      assert {:ok, 41_985} = Costs.core_awake_seconds(ctx.period_start, ctx.now)

      query = MockPrometheusClient.last_query()
      assert query =~ "sum(count_over_time(stacks_fuse_state_state{"
      assert query =~ ~s|fuse_name="vision_fuse"|
      # the window is the elapsed period, not a fixed lookback
      window_s = DateTime.diff(ctx.now, ctx.period_start, :second)
      assert query =~ "[#{window_s}s]))"
    end

    test "returns :error when the metrics store is unreachable" do
      MockPrometheusClient.put_response({:error, :nxdomain})

      assert :error =
               Costs.core_awake_seconds(
                 ~U[2026-08-01 00:00:00.000000Z],
                 ~U[2026-08-13 12:00:00.000000Z]
               )
    end

    test "returns :error when the store holds no samples for the series" do
      MockPrometheusClient.put_response({:ok, 0.0})

      assert :error =
               Costs.core_awake_seconds(
                 ~U[2026-08-01 00:00:00.000000Z],
                 ~U[2026-08-13 12:00:00.000000Z]
               )
    end
  end

  describe "seed_current_period_costs/0" do
    defp beginning_of_current_month do
      now = DateTime.utc_now()
      %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
    end

    defp end_of_current_month do
      now = DateTime.utc_now()
      days = Calendar.ISO.days_in_month(now.year, now.month)
      %{now | day: days, hour: 23, minute: 59, second: 59, microsecond: {999_999, 6}}
    end

    test "populates current_period_costs/0 with the static line items" do
      assert Costs.current_period_costs() == []

      Costs.seed_current_period_costs()

      costs = Costs.current_period_costs()
      assert costs != []
      assert length(costs) == 11
    end

    test "seeded items sum to a positive total (1660 cents with Modal at 0)" do
      Costs.seed_current_period_costs()

      total_cents =
        Costs.current_period_costs()
        |> Enum.reduce(0, fn c, acc -> acc + c.amount_cents end)

      assert total_cents > 0
      assert total_cents == 1660
    end

    test "every seeded row's period lies inside the current calendar month" do
      Costs.seed_current_period_costs()

      month_start = beginning_of_current_month()
      month_end = end_of_current_month()

      seeded_rows = Core.Repo.all(PlatformCost)
      assert length(seeded_rows) == 11

      for cost <- seeded_rows do
        assert DateTime.compare(cost.period_start, month_start) == :eq
        assert DateTime.compare(cost.period_end, month_end) == :eq
      end
    end

    test "is idempotent — running twice does not duplicate rows" do
      Costs.seed_current_period_costs()
      Costs.seed_current_period_costs()

      assert length(Costs.current_period_costs()) == 11
    end
  end

  describe "seed_current_period_costs/0 telemetry (Layer 11)" do
    test "emits one [:stacks, :costs, :recorded] event per line item" do
      attach_telemetry([[:stacks, :costs, :recorded]])

      Costs.seed_current_period_costs()

      events = collect_costs_events(11)
      assert length(events) == 11

      refute_receive {:telemetry_event, [:stacks, :costs, :recorded], _, _}, 50

      for {measurements, metadata} <- events do
        assert is_integer(measurements.amount_cents)
        assert is_binary(metadata.category)
        assert is_binary(metadata.service)
      end

      services = Enum.map(events, fn {_m, metadata} -> metadata.service end)

      assert Enum.sort(services) ==
               Enum.sort([
                 "Fly.io Core",
                 "Fly.io Services",
                 "Modal GPU Inference",
                 # ⛔ A SEPARATE LINE BECAUSE IT IS A SEPARATE COST. The
                 # inference line's own text admitted it omitted the idle tail;
                 # this is that tail, and it had to be declared in
                 # `@telemetry_services` because the counter collapsed it to
                 # "other" the moment it existed.
                 "Modal GPU Idle",
                 "Together AI",
                 "Neon PostgreSQL",
                 "Resend",
                 "Brave Search API",
                 "Google Books & Open Library",
                 "Axiom",
                 "Domain Registration"
               ])
    end
  end

  describe "current_period_costs/0 month scoping (Layer 13)" do
    test "includes current-month rows and excludes a prior-month row" do
      now = DateTime.utc_now()

      {prev_year, prev_month} =
        if now.month == 1, do: {now.year - 1, 12}, else: {now.year, now.month - 1}

      prior_days = Calendar.ISO.days_in_month(prev_year, prev_month)

      prior_start = %{
        now
        | year: prev_year,
          month: prev_month,
          day: 1,
          hour: 0,
          minute: 0,
          second: 0,
          microsecond: {0, 6}
      }

      prior_end = %{
        now
        | year: prev_year,
          month: prev_month,
          day: prior_days,
          hour: 23,
          minute: 59,
          second: 59,
          microsecond: {999_999, 6}
      }

      prior_row =
        insert(:platform_cost,
          category: "hosting",
          service: "Prior Month Service",
          amount_cents: 999,
          currency: "USD",
          period_start: prior_start,
          period_end: prior_end
        )

      Costs.seed_current_period_costs()

      costs = Costs.current_period_costs()
      services = Enum.map(costs, & &1.service)

      refute "Prior Month Service" in services
      refute Enum.any?(costs, &(&1.id == prior_row.id))

      assert "Fly.io Core" in services
      assert length(costs) == 11
    end
  end

  describe "counts that must outlive the Oban pruner" do
    alias Stacks.Transparency.MockPrometheusClient
    # Job rows are pruned, so any month-to-date figure derived by counting rows
    # in `oban_jobs` reports only the retention window — on the public cost
    # page, whose whole claim is that the numbers are measured.
    #
    # ⚠️ The window was Oban's default of sixty SECONDS when this was written
    # and is now an explicit seven days. The requirement is unchanged: seven
    # days is still not a month, and these counts must outlive any retention
    # setting rather than depend on one.
    #
    # These pin the requirement rather than the implementation: with the job
    # table empty, both figures must still be right, which is only possible if
    # they no longer read it.

    setup do
      MockPrometheusClient.reset()
      on_exit(&MockPrometheusClient.reset/0)
      :ok
    end

    test "emails sent are counted with no delivery job rows present" do
      MockPrometheusClient.put_response(fn promql ->
        if String.contains?(promql, "stacks_email_delivered_count_total"),
          do: {:ok, 3.0},
          else: {:ok, 0.0}
      end)

      assert Core.Repo.aggregate(Oban.Job, :count) == 0
      assert Costs.emails_this_month() == {:ok, 3}
    end

    test "vision inferences are counted with no vision job rows present" do
      MockPrometheusClient.put_response(fn promql ->
        if String.contains?(promql, "stacks_vision_request_stop_duration_milliseconds_count"),
          do: {:ok, 2.0},
          else: {:ok, 0.0}
      end)

      assert Core.Repo.aggregate(Oban.Job, :count) == 0
      assert Costs.vision_jobs_this_month() == {:ok, 2}
    end

    test "an unreachable metric store yields no count, and never a zero" do
      MockPrometheusClient.put_response({:error, :unreachable})

      assert Costs.emails_this_month() == :error
      assert Costs.vision_jobs_this_month() == :error
    end

    test "an unavailable inference count is not priced as zero inferences" do
      now = DateTime.utc_now()

      [modal] =
        Costs.build_cost_items(now, now, nil)
        |> Enum.filter(&(&1.service == "Modal GPU Inference"))

      assert modal.description =~ "temporarily unavailable"
      refute modal.description =~ "0 inferences"
    end
  end

  describe "a cost line says how its figure was arrived at" do
    # ⛔ FIVE BUILDERS ANSWERED AN UNAVAILABLE MEASUREMENT WITH `amount_cents: 0`,
    # and their own descriptions said so — Modal's reads "this month's inference
    # count is temporarily unavailable, so no charge is shown". The description
    # was right and the number contradicted it, on a page whose closing line
    # claimed every number was real.
    #
    # ⚠️ This surfaced only after the upstream fix: stopping
    # `metric_count_this_month/1` mapping :no_data to {:ok, 0} let the nil
    # clauses run, and the nil clauses did the same conversion themselves. Two
    # layers of one defect, the second invisible until the first was gone.
    test "an unavailable measurement is absent, not zero" do
      {:ok, period_start} = DateTime.new(~D[2026-11-01], ~T[00:00:00.000000])
      {:ok, period_end} = DateTime.new(~D[2026-11-30], ~T[23:59:59.999999])

      items = Costs.build_cost_items(period_start, period_end, nil, [])

      modal = Enum.find(items, &(&1.service == "Modal GPU Inference"))

      assert modal.basis == "absent",
             "an unmeasured line is not marked absent, so the page renders its placeholder " <>
               "zero as a real $0.00 for a service it has no measurement of"
    end

    # ⬛ ANTI-VACUITY, and it is the half that stops a blanket "absent": a line
    # WITH a measurement must say so, or marking everything absent would satisfy
    # the case above and blank the entire page.
    test "a measured line is not marked absent" do
      {:ok, period_start} = DateTime.new(~D[2026-11-01], ~T[00:00:00.000000])
      {:ok, period_end} = DateTime.new(~D[2026-11-30], ~T[23:59:59.999999])

      items =
        Costs.build_cost_items(period_start, period_end, 120, gpu_active_seconds: 900)

      modal = Enum.find(items, &(&1.service == "Modal GPU Inference"))

      assert modal.basis == "rate_card"
      assert modal.amount_cents > 0
    end

    # ⚖️ A published-price fallback is RATE_CARD, not ABSENT. Three of the eight
    # nil clauses fall back to a constant rather than to zero — those lines do
    # carry a defensible figure, and calling them absent would be the same
    # dishonesty pointed the other way.
    test "a published-price fallback is rate_card, not absent" do
      {:ok, period_start} = DateTime.new(~D[2026-11-01], ~T[00:00:00.000000])
      {:ok, period_end} = DateTime.new(~D[2026-11-30], ~T[23:59:59.999999])

      items = Costs.build_cost_items(period_start, period_end, nil, [])

      neon = Enum.find(items, &(&1.service =~ "Neon"))

      assert neon.basis == "rate_card"

      # ⬛ AND THE AMOUNT IS NOT ASSERTED NON-ZERO, deliberately: `@neon_cents`
      # is 0 because Neon's published price for this tier IS zero. That makes
      # the crucial point explicit — a rate-card zero and a measured zero are
      # both HONEST ("the free tier costs nothing"), and only an ABSENT figure
      # must not render as money. The defect was never "zero is bad"; it was a
      # zero standing in for a number nobody had.
      #
      # ⚠️ My first version of this case asserted `> 0` and failed, on the
      # assumption that a rate-card line must carry a charge. It does not, and
      # `basis` rather than the amount is the thing that separates the honest
      # zeros from the lying one.
      assert is_integer(neon.amount_cents)
    end

    # ⛔ THE VOCABULARY IS CLOSED AT THE DATABASE, not only in the changeset,
    # because the factory and any future non-changeset writer bypass the
    # changeset entirely — and a typo putting an unknown basis on a line would
    # put a $0.00 back on a figure that does not exist.
    test "an unknown basis is refused" do
      {:ok, period_start} = DateTime.new(~D[2026-11-01], ~T[00:00:00.000000])
      {:ok, period_end} = DateTime.new(~D[2026-11-30], ~T[23:59:59.999999])

      changeset =
        Costs.platform_cost_changeset(%Stacks.Costs.PlatformCost{}, %{
          category: "compute",
          service: "Probe",
          amount_cents: 1,
          currency: "USD",
          period_start: period_start,
          period_end: period_end,
          basis: "guessed"
        })

      refute changeset.valid?
    end
  end

  describe "a category total does not sum figures nobody has" do
    # ⛔ THE PER-LINE FIX LANDED AND THE HEADER STILL LIED. A browser drive on a
    # live stack found "Compute $0.00" over one measured Modal line and one
    # unmeasured Together AI line — the same false claim the basis field removes
    # at the line, at the altitude most readers stop at. 4591 Elixir tests, 2314
    # Elm tests, 9 E2E specs and a GDPR lens all passed while it was there.
    #
    # ⚠️ The E2E spec could not have caught it: it asserted
    # `.costs__service-amount`, the elements the fix changed, and nothing on
    # `.costs__category-total`. A test shaped around the fix cannot find what
    # the fix missed.
    test "an absent line is excluded from its category total" do
      {:ok, period_start} = DateTime.new(~D[2026-11-01], ~T[00:00:00.000000])
      {:ok, period_end} = DateTime.new(~D[2026-11-30], ~T[23:59:59.999999])

      measured = %{
        category: "compute",
        service: "Measured Thing",
        description: "d",
        amount_cents: 500,
        currency: "USD",
        basis: "rate_card",
        period_start: period_start,
        period_end: period_end
      }

      # ⛔ A NON-ZERO PLACEHOLDER, AND THE FIXTURE IS DELIBERATELY UNREALISTIC.
      #
      # Production absent lines carry `amount_cents: 0`, and my first version of
      # this test used that — which made the whole assertion VACUOUS: summing a
      # zero or excluding it gives the same total, so the test passed with the
      # defect restored. The probe caught it, which is the only reason I know.
      #
      # ⚖️ The rule under test is "an absent line is excluded", and testing a
      # rule requires an input whose inclusion would be VISIBLE. A zero
      # placeholder cannot distinguish the two behaviours, so the fixture uses a
      # figure that can — even though no builder emits one.
      absent = %{measured | service: "Unmeasured Thing", amount_cents: 999, basis: "absent"}

      for attrs <- [measured, absent] do
        {:ok, _} = Costs.upsert_cost(attrs)
      end

      compute =
        Costs.cost_breakdown()
        |> Map.fetch!(:categories)
        |> Enum.find(&(&1.category == "compute"))

      assert compute.total_cents == 500,
             "the absent line was summed into the category total — a reader who never " <>
               "scrolls past the header sees the figure this issue exists to remove"

      assert compute.unmeasured_count == 1,
             "the total excludes the absent line but does not SAY so, which under-reports " <>
               "while looking complete"
    end

    # ⛔ THE HEADLINE TOTAL AND THE HISTORICAL SERIES TOO — the other two of four
    # aggregation sites, caught by a reviewer re-driving the diff after the
    # first two were fixed.
    #
    # ⚠️ The case above already had a fixture shaped to catch this and did not
    # assert it, so it passed while `current_total` summed the absent line. That
    # is the same vacuity I had just caught one level down: a fixture that CAN
    # distinguish two behaviours proves nothing unless something reads the
    # number it distinguishes.
    test "the top-level total excludes absent lines" do
      {:ok, period_start} = DateTime.new(~D[2026-11-01], ~T[00:00:00.000000])
      {:ok, period_end} = DateTime.new(~D[2026-11-30], ~T[23:59:59.999999])

      measured = %{
        category: "compute",
        service: "Measured Thing",
        description: "d",
        amount_cents: 500,
        currency: "USD",
        basis: "rate_card",
        period_start: period_start,
        period_end: period_end
      }

      # The same deliberately unrealistic non-zero placeholder: production
      # absent rows carry 0, which makes their inclusion invisible.
      absent = %{measured | service: "Unmeasured Thing", amount_cents: 999, basis: "absent"}

      for attrs <- [measured, absent] do
        {:ok, _} = Costs.upsert_cost(attrs)
      end

      breakdown = Costs.cost_breakdown()

      assert breakdown.total_cents == 500,
             "the headline total summed a figure nobody has — this and cost_per_book are the " <>
               "FIRST numbers a reader sees, above every line already corrected below"

      refute Enum.any?(breakdown.monthly_totals, &(&1.total_cents == 1499)),
             "the historical series includes the absent line — a chart that lies about the " <>
               "past, where nobody will re-check it"
    end

    # ⬛ ANTI-VACUITY: a category with nothing absent reports zero unmeasured, or
    # a header that always said "+ N unmeasured" would satisfy the case above
    # and cry wolf on every complete category.
    test "a category with every figure present reports none unmeasured" do
      {:ok, period_start} = DateTime.new(~D[2026-11-01], ~T[00:00:00.000000])
      {:ok, period_end} = DateTime.new(~D[2026-11-30], ~T[23:59:59.999999])

      {:ok, _} =
        Costs.upsert_cost(%{
          category: "database",
          service: "All Measured",
          description: "d",
          amount_cents: 700,
          currency: "USD",
          basis: "measured",
          period_start: period_start,
          period_end: period_end
        })

      database =
        Costs.cost_breakdown()
        |> Map.fetch!(:categories)
        |> Enum.find(&(&1.category == "database"))

      assert database.unmeasured_count == 0
      assert database.total_cents == 700
    end
  end

  describe "the budget ceiling's two Modal constants are independent" do
    # ⛔ THEY WERE ONE CONSTANT, AND THAT SILENTLY HALVED THE GUARD'S TRIP
    # POINT. `modal_gpu_inference_surcharge_cents/0` returned the baseline, on
    # the reasoning that two constants for one price is how they drift — but
    # these are two different quantities: a conservative all-in ceiling per
    # call, and the incremental cost of waking a GPU. While they were equal, a
    # VLM call charged 6c where it had charged 3c, so the Modal ceiling tripped
    # at HALF the call volume, and nothing said so.
    test "the baseline and the GPU surcharge are separate figures" do
      baseline = Costs.modal_budget_estimate_cents_per_call()
      surcharge = Costs.modal_gpu_inference_surcharge_cents()

      assert baseline == 3
      assert surcharge == 3
    end

    # ⬛ ANTI-VACUITY, and it is the whole point of the split: the two must be
    # settable independently. They are EQUAL today, so an equality assertion
    # cannot tell a shared constant from two that agree — only changing one and
    # observing the other hold distinguishes them.
    #
    # ⚖️ Expressed as a claim about the SOURCE rather than the value, because a
    # runtime test cannot rebind a module attribute: if these two functions
    # ever return the same attribute again, this is the comment that says why
    # that is wrong.
    test "the two figures are read from different attributes" do
      source = File.read!(Path.join([__DIR__, "..", "..", "lib", "stacks", "costs.ex"]))

      assert source =~
               "def modal_budget_estimate_cents_per_call, do: @modal_budget_estimate_cents_per_call"

      assert source =~ "def modal_gpu_inference_surcharge_cents, do: @modal_gpu_surcharge_cents",
             "the GPU surcharge is being read from the baseline attribute again — a VLM call " <>
               "then charges twice the baseline and the Modal ceiling trips at half the call " <>
               "volume, which is an operational change that must be stated rather than inherited"
    end
  end
end
