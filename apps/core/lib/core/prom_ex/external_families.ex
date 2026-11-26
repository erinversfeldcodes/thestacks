defmodule Core.PromEx.ExternalFamilies do
  @moduledoc """
  Metric families that reach the store without this application registering them.

  ⛔ **The dashboard gates had a universe, and half the store was outside it.**
  `DashboardCompletenessTest` asks "does every measured family have a panel?"
  and `PlatformOpsDriftTest` asks "does every panel reference a measured
  family?" — and both computed *measured* from `Core.PromEx.Plugins.Stacks`,
  the families this app registers. A series pushed by something else is in the
  store and not in that set, so the first gate passed **vacuously** over it and
  the second gate **actively forbade** a panel for it.

  That combination is worse than either alone: the billing series — the only
  figures anywhere that come from a provider's invoice rather than our own
  arithmetic — had no panel, and anyone who tried to add one would have been
  stopped by a green-making gate telling them the metric did not exist.

  ⚖️ So the universe is declared rather than widened. A wildcard (`allow any
  stacks_billing_*`) would have fixed the drift failure and left the
  completeness hole open forever, because a set you cannot enumerate cannot be
  required to have panels. Every family here names its pusher, so "who writes
  this?" is answerable from one file.

  ⚠️ **Adding a family here is a claim that something outside this app writes
  it.** If that pusher stops, nothing in this module notices — a declaration is
  not a liveness check. `scripts/push_billing_metrics.py` runs on a daily cron
  and its workflow failing is how you learn it stopped.
  """

  @external %{
    "stacks_billing_mtd_cents" => %{
      pusher: "scripts/push_billing_metrics.py",
      caller: ".github/workflows/refresh-billing-metrics.yml (cron 43 4 * * *)",
      why:
        "Month-to-date spend read from each provider's own billing API. The only series here " <>
          "that is an invoice rather than a published price times a quantity we counted — so it " <>
          "is the only way to detect that one of our own rate constants is wrong."
    },
    "stacks_billing_run_rate_cents_per_month" => %{
      pusher: "scripts/push_billing_metrics.py",
      caller: ".github/workflows/refresh-billing-metrics.yml (cron 43 4 * * *)",
      why: "Current spend extrapolated to a month, for noticing a step change with no deploy."
    },
    # ⛔ ELEVEN FAMILIES THAT WERE PUSHED, UNDECLARED, UNCLASSIFIED AND
    # UNPANELED — found by a reviewer, not by any gate. Every one is a
    # scheduled job's health signal, which makes them the worst possible set to
    # have invisible: a cron that stops running produces no errors anywhere,
    # and these series are the only thing that would say so.
    #
    # ⚖️ They are declared here rather than left out because declaring them is
    # what makes the completeness gate DEMAND a panel for each. Leaving them
    # undeclared is what kept them invisible: the gate's universe was the
    # PromEx plugin, so a pushed family was neither required to be displayed
    # nor permitted to be.
    "stacks_backup_dump_last_success_timestamp_seconds" => %{
      pusher: ".github/workflows/backup-dump.yml",
      caller: "same file, cron 17 3 * * *",
      why:
        "When the database dump last succeeded. A timestamp rather than a success counter, because the failure that matters is the one where nothing runs at all — a counter that stops incrementing looks identical to a quiet period, while an ageing timestamp is unmistakable."
    },
    "stacks_backup_dump_size_bytes" => %{
      pusher: ".github/workflows/backup-dump.yml",
      caller: "same file, cron 17 3 * * *",
      why:
        "Dump size. Watch for it collapsing: a backup that succeeds and contains almost nothing is the failure mode a success flag cannot see."
    },
    "stacks_backup_dump_duration_seconds" => %{
      pusher: ".github/workflows/backup-dump.yml",
      caller: "same file, cron 17 3 * * *",
      why: "How long the dump took, for noticing growth before it hits the workflow timeout."
    },
    "stacks_costs_refresh_last_success_timestamp_seconds" => %{
      pusher: ".github/workflows/scheduled-core-jobs.yml",
      caller: "same file, cron 0 6 * * *",
      why:
        "When the cost figures were last refreshed. ⚠️ The public cost page reads month-to-date series with a 48h lookback, so a refresh that silently stops leaves the page showing a figure that ages without ever looking stale."
    },
    "stacks_costs_refresh_duration_seconds" => %{
      pusher: ".github/workflows/scheduled-core-jobs.yml",
      caller: "same file, cron 0 6 * * *",
      why: "Duration of the cost refresh."
    },
    "stacks_costs_refresh_items" => %{
      pusher: ".github/workflows/scheduled-core-jobs.yml",
      caller: "same file, cron 0 6 * * *",
      why:
        "How many cost line items were written. A drop means a builder clause stopped producing a line, which on a transparency page reads as a service that costs nothing."
    },
    "stacks_bookstore_events_sweep_last_success_timestamp_seconds" => %{
      pusher: ".github/workflows/scheduled-core-jobs.yml",
      caller: "same file, cron 30 7 * * 1",
      why:
        "When the bookstore event sweep last succeeded. Weekly, so an ageing timestamp needs a wider tolerance than the daily jobs before it means anything."
    },
    "stacks_bookstore_events_sweep_duration_seconds" => %{
      pusher: ".github/workflows/scheduled-core-jobs.yml",
      caller: "same file, cron 30 7 * * 1",
      why: "Duration of the weekly bookstore event sweep."
    },
    "stacks_dbt_refresh_last_success_timestamp_seconds" => %{
      pusher: ".github/workflows/scheduled-dbt-refresh.yml",
      caller: "same file, cron 11 4 * * *",
      why:
        "When the warehouse models were last rebuilt. Everything downstream of the marts inherits this staleness without reporting it."
    },
    "stacks_dbt_refresh_duration_seconds" => %{
      pusher: ".github/workflows/scheduled-dbt-refresh.yml",
      caller: "same file, cron 11 4 * * *",
      why: "Duration of the dbt refresh."
    },
    "stacks_dbt_refresh_mart_rows" => %{
      pusher: ".github/workflows/scheduled-dbt-refresh.yml",
      caller: "same file, cron 11 4 * * *",
      why:
        "Rows in the marts after a refresh. ⛔ A zero here is the shape this project has been bitten by: a pipeline that runs, reports success, and delivers nothing."
    },
    "stacks_billing_allowance_pct" => %{
      pusher: "scripts/push_billing_metrics.py",
      caller: ".github/workflows/refresh-billing-metrics.yml (cron 43 4 * * *)",
      why:
        "Free-tier consumption. The cost page reports Neon at zero BECAUSE of this allowance, " <>
          "not because the database is free, so this is what makes that zero honest."
    }
  }

  @doc "Families written by something outside this application."
  @spec families() :: [String.t()]
  def families, do: Map.keys(@external)

  @doc "Provenance for one externally-pushed family."
  @spec provenance(String.t()) :: map() | nil
  def provenance(family), do: Map.get(@external, family)

  @doc "Every declared family with its provenance."
  @spec all() :: map()
  def all, do: @external
end
