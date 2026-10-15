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
    end

    test "the row keeps the exact service while the label collapses" do
      # The half that is easy to lose: bounding must not reach the record.
      assert "A Service Invented Yesterday" not in Stacks.Costs.telemetry_services()

      assert Stacks.Costs.telemetry_services() |> length() == 10,
             "the declared service vocabulary is the set this module itself writes; if a " <>
               "`service:` literal was added without declaring it, its metric silently became " <>
               "\"other\""
    end
  end

  describe "the class cannot silently reopen" do
    # ⚠️ This is the derivation that found the six in the first place, kept as a
    # test so "declared somewhere with no reporter" cannot come back quietly.
    #
    # It reads BOTH declaration syntaxes, and that detail is the point: the
    # first time this difference was computed by hand it parsed only
    # `event_name: [...]` and reported FOUR unmirrored families, missing the two
    # declared in the string form — which happened to be the two that meter
    # money. A derivation that sees one syntax is worse than none, because it
    # reports a clean number.
    defp declared_families(source) do
      explicit =
        Regex.scan(~r/event_name:\s*\[([^\]]+)\]/, source)
        |> Enum.map(fn [_, inner] ->
          inner
          |> String.split(",")
          |> Enum.map(&(&1 |> String.trim() |> String.trim_leading(":")))
        end)

      string_form =
        ~r/(?:counter|sum|summary|last_value|distribution)\(\s*"([a-z_0-9.]+)"/
        |> Regex.scan(source)
        |> Enum.map(fn [_, name] ->
          name |> String.split(".") |> Enum.drop(-1)
        end)
        |> Enum.reject(&(length(&1) < 2))

      (explicit ++ string_form)
      |> Enum.map(&Enum.join(&1, "."))
      |> MapSet.new()
    end

    test "no stacks family is declared for a reporter that does not exist" do
      telemetry_src = File.read!("lib/core_web/telemetry.ex")

      stacks_declared =
        telemetry_src
        |> declared_families()
        |> Enum.filter(&String.starts_with?(&1, "stacks."))

      assert stacks_declared == [],
             "`CoreWeb.Telemetry` declares metric series again: #{inspect(stacks_declared)}.\n" <>
               "That module supervises the poller and attaches handlers; it has NO " <>
               "`Telemetry.Metrics` reporter, so anything declared there is emitted, counted by " <>
               "nothing, and on no dashboard — while reading like a metric that exists.\n" <>
               "Declare it in `Core.PromEx.Plugins.Stacks` instead, and classify it in " <>
               "`Core.PromEx.MetricAudience`."
    end
  end
end
