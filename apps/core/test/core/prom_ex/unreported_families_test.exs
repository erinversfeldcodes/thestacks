defmodule Core.PromEx.UnreportedFamiliesTest do
  @moduledoc """
      Six telemetry families fired in production, were covered by firing tests,
      and reached no metrics store — they were declared only in
      `CoreWeb.Telemetry.metrics/0`, whose supervisor holds a `:telemetry_poller`
      and no reporter. Two of them meter MONEY: the spend the budget guard stops
      AI work over, and the figures the public cost page reports.

      ⚠️ The bar here is deliberately not "a metric is declared in the plugin".
      A declaration is what the six already had. These tests emit the real event
      and read the real scrape output, because the only thing that distinguishes
      an observable metric from a declared one is that a value comes back.

      They also pin the two labels that were unbounded AT SOURCE. `provider`
      arrives as `to_string/1` on a caller-supplied atom and `service` is a
      free-text column, so both are bounded at the emit site: the row keeps the
      exact value, the label collapses to "other". Both directions are asserted,
      because a function that collapsed everything would pass a test that only
      checked the unknown case.
  """

  # `Core.DataCase` rather than `ExUnit.Case`: the service-bounding test goes
  # through `Costs.upsert_cost/1`, which writes a row. async: false because
  # PromEx's registry is global state and these tests read the scrape output.
  use Core.DataCase, async: false

  alias Core.PromEx.MetricAudience
  alias Core.PromEx.Plugins.Stacks, as: StacksPlugin
  alias Stacks.AI.BudgetTracker

  # family => the event that must produce it
  @families %{
    "stacks_budget_cost_recorded_amount_cents" => [:stacks, :budget, :cost_recorded],
    "stacks_budget_limit_exceeded_count_total" => [:stacks, :budget, :limit_exceeded],
    "stacks_costs_recorded_amount_cents" => [:stacks, :costs, :recorded],
    "stacks_fuse_melt_count_total" => [:stacks, :fuse, :melt],
    "stacks_fuse_blown_count_total" => [:stacks, :fuse, :blown],
    "stacks_crawler_robots_fetch_count_total" => [:stacks, :crawler, :robots_fetch]
  }

  defp scrape do
    Process.sleep(50)
    output = PromEx.get_metrics(Core.PromEx)
    refute output == :prom_ex_down, "Core.PromEx must be running for this test"
    output
  end

  defp lines_for(output, family) do
    for line <- String.split(output, "\n"),
        String.starts_with?(line, family <> "{") or String.starts_with?(line, family <> " "),
        do: line
  end

  describe "the six families reach the scrape output" do
    test "each one appears after its event fires" do
      # Fire all six, then scrape once — a family that needs its own scrape to
      # appear would still be observable, and this is cheaper.
      # ⚠️ Deliberately NOT provider: "modal" here.
      #
      # These are direct emits, which bypass the bounding at the emit site. If
      # they minted a `provider="modal"` series, the "known provider passes
      # through" test below would be satisfied by THIS fixture rather than by
      # the bounding working — and it was: a probe that collapsed every provider
      # to "other" left the whole file green, because the only `modal` series in
      # the registry had been put there by this test. The registry is global and
      # accumulates across tests in a run, so a presence fixture can silently
      # satisfy a sibling's assertion.
      :telemetry.execute([:stacks, :budget, :cost_recorded], %{amount_cents: 7}, %{
        provider: "other"
      })

      :telemetry.execute([:stacks, :budget, :limit_exceeded], %{}, %{
        provider: "other",
        type: :daily
      })

      :telemetry.execute([:stacks, :costs, :recorded], %{amount_cents: 11}, %{
        category: "compute",
        service: "Modal GPU Inference"
      })

      :telemetry.execute([:stacks, :fuse, :melt], %{}, %{fuse_name: :vision_fuse})
      :telemetry.execute([:stacks, :fuse, :blown], %{}, %{fuse_name: :vision_fuse})
      :telemetry.execute([:stacks, :crawler, :robots_fetch], %{count: 1}, %{})

      output = scrape()

      missing =
        for {family, _event} <- @families,
            lines_for(output, family) == [],
            do: family

      assert missing == [],
             "these families fired but did not reach the scrape output — a declaration is not a " <>
               "reporter: #{inspect(missing)}"
    end

    test "each one is registered by the plugin under the expected family name" do
      registered =
        StacksPlugin.event_metrics([])
        |> Enum.flat_map(& &1.metrics)
        |> Enum.map(&Enum.join(&1.name, "_"))
        |> MapSet.new()

      for {family, _event} <- @families do
        assert MapSet.member?(registered, family),
               "#{family} is not registered by Core.PromEx.Plugins.Stacks"
      end
    end

    test "the cost family is a GAUGE, because the writer is idempotent" do
      # ⚠️ The assertion that would have caught this family shipping as a `sum`.
      #
      # `Costs.upsert_cost/1` replaces the row for its {service, period} key and
      # fires on every success, and `RefreshCostsJob` re-upserts all ten items
      # daily for the CURRENT month — so each day's event carries the
      # month-to-date total, which already contains every earlier day's. Summed,
      # the series holds Σ(MTD₁ … MTD_N), which is not a cost; and because
      # `Telemetry.Metrics.Sum` renders as a Prometheus counter it is monotonic,
      # so the error never resets at the month boundary. The dashboard panel
      # asserted these were the figures the public cost page reports. They would
      # not have been.
      #
      # Nothing in this file could see that: every other assertion here checks a
      # family is PRESENT, and a wrong-typed series is present. The exposition
      # format carries the type, so that is what to read.
      :telemetry.execute([:stacks, :costs, :recorded], %{amount_cents: 13}, %{
        category: "compute",
        service: "other"
      })

      output = scrape()

      assert output =~ "# TYPE stacks_costs_recorded_amount_cents gauge",
             "the cost series must be a gauge. It reports a LEVEL — what the period has cost so " <>
               "far — written by an idempotent upsert that re-states the running total every " <>
               "day. As a counter it would accumulate running totals of running totals and never " <>
               "reset."

      refute output =~ "# TYPE stacks_costs_recorded_amount_cents counter",
             "a counter here compounds the double-count forever rather than self-healing"
    end

    test "each one carries a deliberate audience classification" do
      for {family, _event} <- @families do
        audience = MetricAudience.audience(family)

        refute audience == :unclassified,
               "#{family} has no audience; MetricAudience is fail-closed, so an unclassified " <>
                 "family silently reaches no public surface rather than failing loudly here"
      end
    end
  end

  describe "labels bounded at the emit site" do
    test "a known provider passes through unchanged" do
      # Through the real API, so the assertion is about `bounded_provider/1`
      # and not about what this test chose to emit.
      BudgetTracker.record_cost(:modal, 3)

      output = scrape()

      assert Enum.any?(
               lines_for(output, "stacks_budget_cost_recorded_amount_cents"),
               &String.contains?(&1, ~s(provider="modal"))
             ),
             "a declared provider must label as itself — a bounding function that collapsed " <>
               "everything would pass the unknown-value test below while destroying the metric"
    end

    test "an undeclared provider collapses to other" do
      # The shape that made this unbounded: a caller passing any atom at all.
      BudgetTracker.record_cost(:some_provider_nobody_declared, 5)

      output = scrape()
      lines = lines_for(output, "stacks_budget_cost_recorded_amount_cents")

      refute Enum.any?(lines, &String.contains?(&1, "some_provider_nobody_declared")),
             "an undeclared provider reached the label set; `provider` is `to_string/1` on " <>
               "caller input, so this is an unbounded cardinality commitment to the store"

      assert Enum.any?(lines, &String.contains?(&1, ~s(provider="other"))),
             "an undeclared provider must label as \"other\" — visible under-labelling is the " <>
               "signal to come and declare it, and is what makes the bound safe to keep narrow"
    end

    test "a known service passes through and an unknown one collapses" do
      # ⚠️ Through `Costs.upsert_cost/1`, NOT `:telemetry.execute/3`.
      #
      # The first version of this test emitted the event directly with a
      # free-text service and failed — correctly. Emitting the event by hand
      # bypasses the bounding, which lives at the emit site inside this
      # function, so the test would have been asserting its own fixture rather
      # than the code. The provider test above goes through
      # `BudgetTracker.record_cost/2` for the same reason.
      {:ok, _} =
        Stacks.Costs.upsert_cost(%{
          category: "compute",
          service: "Neon PostgreSQL",
          description: "known service",
          amount_cents: 2,
          period_start: ~U[2026-10-01 00:00:00.000000Z],
          period_end: ~U[2026-10-31 00:00:00.000000Z]
        })

      {:ok, _} =
        Stacks.Costs.upsert_cost(%{
          category: "compute",
          service: "A Service Invented Yesterday",
          description: "undeclared service",
          amount_cents: 2,
          period_start: ~U[2026-10-01 00:00:00.000000Z],
          period_end: ~U[2026-10-31 00:00:00.000000Z]
        })

      output = scrape()
      lines = lines_for(output, "stacks_costs_recorded_amount_cents")

      assert Enum.any?(lines, &String.contains?(&1, ~s(service="Neon PostgreSQL"))),
             "a declared service must label as itself"

      refute Enum.any?(lines, &String.contains?(&1, "Invented Yesterday")),
             "a free-text service name reached the label set; the column has no validation, so " <>
               "every new name would mint a new series forever"

      assert Enum.any?(lines, &String.contains?(&1, ~s(service="other"))),
             "the undeclared service must land as \"other\" rather than vanishing — an " <>
               "unattributed cost is still a cost, and a dropped series would hide it"

      # ⚠️ The other half of the contract, and it was asserted by a test NAME
      # rather than by a test: bounding collapses the LABEL and must not reach
      # the RECORD. Nothing here read a row until this line — the rows were
      # created above and dropped, so "the row keeps the exact service" was a
      # claim nothing could falsify.
      assert Core.Repo.get_by(Stacks.Costs.PlatformCost,
               service: "A Service Invented Yesterday"
             ),
             "the bounding reached the RECORD — only the label may collapse. The row is the " <>
               "ledger; an unattributable cost must still be attributable in the database."
    end

    test "the declared service vocabulary is exactly what the module writes" do
      # ⚠️ Read off the CALLER, not the allowlist, and assert EQUALITY.
      #
      # This replaced `length(telemetry_services()) == 10`, which was green on
      # the defect its own message named: the `service:` literals live in
      # `Stacks.Costs`'s own builders, and a count of the allowlist cannot see a
      # literal added without being declared. It was wrong in both directions —
      # green when a literal drifted, red when one was correctly declared.
      #
      # Equality over a live function's output also cannot go vacuous. A
      # regex-derived check would be a SUBSET assertion (`scanned ⊆ allowlist`)
      # that an empty scan satisfies, which is exactly why `metric_label_test`
      # had to grow `scan_with_floor!/1` and three per-pattern floors. Here, if
      # `build_cost_items/4` returned `[]` the assertion fails on its own.
      #
      # Complete only while `build_cost_items/4` reaches every `service:`
      # literal we write — true today. A literal written on some other path
      # would not be seen, and the safety net for that is `bounded_label/2`
      # collapsing it to "other", which is a visible signal rather than a
      # silent one.
      period_start = ~U[2026-10-01 00:00:00.000000Z]
      period_end = ~U[2026-10-31 00:00:00.000000Z]

      written =
        period_start
        |> Stacks.Costs.build_cost_items(period_end, 0)
        |> Enum.map(& &1.service)
        |> Enum.uniq()
        |> Enum.sort()

      assert written == Enum.sort(Stacks.Costs.telemetry_services()),
             "a `service:` literal in Stacks.Costs is not in @telemetry_services, so its metric " <>
               "silently labels as \"other\" — declare it there. " <>
               "written=#{inspect(written)} declared=#{inspect(Enum.sort(Stacks.Costs.telemetry_services()))}"
    end
  end

  describe "the class cannot silently reopen" do
    @repo_root Path.expand("../../../../..", __DIR__)

    # ⚠️ This asserts the IMPORT, not the declarations, and that choice is the
    # whole finding rather than a style preference.
    #
    # The first version of this test derived declared families from
    # `lib/core_web/telemetry.ex` by regex. It was wrong twice over:
    #
    #   - `Telemetry.Metrics` has FOUR ways to name a family and the regexes saw
    #     two. A list name with no `event_name:` is the idiomatic form — the
    #     library's own docs say "by default the event name is all but the last
    #     segment of the metric name" — and a string `event_name:` is the
    #     documented alternative. Neither was matched. This is the same error
    #     recurring: the very first hand-derivation parsed only `event_name:`,
    #     reported four unmirrored families instead of six, and the two it
    #     missed were the two that meter money.
    #   - It read ONE hardcoded file, so a new module declaring series anywhere
    #     else reopened the class with the gate still green. The issue this test
    #     belongs to warns in terms that fixing part of a class is the
    #     instance-not-class error.
    #
    # Scanning raw source for declarations also made the gate hostage to
    # comments: writing `event_name: [:stacks, :repo, :query]` inside a comment
    # — the natural way to explain a mapping — would have reddened it.
    #
    # You cannot declare a `Telemetry.Metrics` series without importing the
    # module, `use`-ing something that imports it, or qualifying the call. One
    # pattern over those three covers all four syntaxes and any fifth, every
    # file, and cannot be tripped by prose.
    #
    # ⚠️ `use PromEx.Plugin` is in the alternation deliberately. It expands to
    # `import Telemetry.Metrics, only: [counter: 2, distribution: 2,
    # last_value: 2, sum: 2]` (`deps/prom_ex/lib/prom_ex/plugin.ex:56`), which
    # is how this project's own plugin declares everything. Without it the
    # pattern matched NOTHING in the tree — including the plugin — so the
    # exclusion below would have been dead config and a new `use PromEx.Plugin`
    # module outside the plugins directory would have been invisible, which is
    # precisely the class.
    @declares_metrics ~r/^\s*(?:import|use)\s+Telemetry\.Metrics|^\s*use\s+PromEx\.Plugin|Telemetry\.Metrics\.(?:counter|sum|summary|last_value|distribution)\(/m

    test "no module outside the PromEx plugins declares Telemetry.Metrics series" do
      offenders =
        Path.join(@repo_root, "apps/core/lib/**/*.ex")
        |> Path.wildcard()
        |> Enum.reject(&String.contains?(&1, "/core/prom_ex/plugins/"))
        |> Enum.filter(&(File.read!(&1) =~ @declares_metrics))
        |> Enum.map(&Path.relative_to(&1, @repo_root))

      assert offenders == [],
             "these modules declare metric series outside the PromEx plugins, where there is no " <>
               "`Telemetry.Metrics` reporter — anything declared there is emitted, counted by " <>
               "nothing, and on no dashboard, while reading like a metric that exists: " <>
               "#{inspect(offenders)}.\n" <>
               "Declare it in `Core.PromEx.Plugins.Stacks` instead, and classify it in " <>
               "`Core.PromEx.MetricAudience`, which is fail-closed."
    end

    test "the exclusion is load-bearing — the real plugin matches the pattern" do
      # Anti-vacuity. Without this, deleting `use PromEx.Plugin` from the
      # alternation leaves the offenders list empty and the suite green, which
      # is exactly how the pattern was wrong when it was first proposed.
      plugin = Path.join(@repo_root, "apps/core/lib/core/prom_ex/plugins/stacks.ex")

      assert File.read!(plugin) =~ @declares_metrics,
             "the pattern no longer recognises how this project actually declares metrics, so " <>
               "the check above is passing because it matches nothing rather than because " <>
               "nothing is wrong"
    end
  end
end
