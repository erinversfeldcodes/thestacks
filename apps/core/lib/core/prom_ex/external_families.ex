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
