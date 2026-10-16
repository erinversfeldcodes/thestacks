defmodule Core.ScheduledDutyPairingTest do
  @moduledoc """
      A scheduled duty removed from the Oban crontab must have a workflow that
      runs it.

      ⚠️ The invariant is a PAIRING, not an absence, and that distinction is the
      whole point of this file. `deploy/fly.core.toml` sets
      `min_machines_running = 0`, and `Oban.Plugins.Cron` computes due jobs on a
      tick from a running node with no catch-up pass — so every crontab entry
      fires only if something else happened to wake the machine in that minute.
      The entries are unreliable, and the obvious response is to delete them.

      **Deleting one on its own makes things worse.** It converts "runs when the
      machine happens to be awake" into "never runs", and a plain
      `refute entry in crontab` assertion is perfectly satisfied by that — it
      would go green on the regression it looks like it is guarding.

      So each moved duty is asserted twice: gone from the crontab, AND named by
      a workflow under `.github/workflows/`. Both directions fail loudly: a
      re-added crontab entry, and a deleted or renamed workflow.
  """

  use ExUnit.Case, async: true

  @workflows_dir Path.expand("../../../../.github/workflows", __DIR__)

  # Each duty: the worker it used to fire, and the release function a workflow
  # must invoke in its place. The release function is the pairing's anchor
  # because it is what actually does the work — a workflow file could exist and
  # call nothing.
  @moved_duties [
    {Stacks.Workers.RefreshCostsJob, "Stacks.Release.refresh_costs"},
    {Stacks.Workers.DiscoverBookstoreEventsJob, "Stacks.Release.discover_bookstore_events"},
    {Stacks.Workers.DbtRefreshJob, "scripts/dbt-deployed.sh"}
  ]

  # Not a target and not an assertion about this number being right — it is the
  # size of the problem that remains, pinned so it cannot grow silently and so
  # closing the follow-up has a number to move.
  @remaining_entries 17

  defp crontab do
    :core
    |> Application.get_env(Oban)
    |> Keyword.fetch!(:plugins)
    |> Enum.find_value(fn
      {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
      _ -> nil
    end)
  end

  defp workflow_corpus do
    @workflows_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, [".yml", ".yaml"]))
    |> Enum.map_join("\n", &File.read!(Path.join(@workflows_dir, &1)))
  end

  test "the workflow corpus is readable — the pairing assertions depend on it" do
    # Anti-vacuity. Every pairing assertion below searches this corpus, so an
    # empty or unreadable one would report that every duty is correctly paired
    # while having looked at nothing.
    corpus = workflow_corpus()

    assert byte_size(corpus) > 10_000,
           "the workflow corpus read #{byte_size(corpus)} bytes from #{@workflows_dir}, which is " <>
             "too small to be this repository's workflows — the pairing assertions would then " <>
             "be searching an empty string and passing for the wrong reason"

    assert corpus =~ "scheduled-dbt-refresh",
           "a workflow this repository is known to have is missing from the corpus, so the " <>
             "search is not reading what it claims to"
  end

  test "every moved duty is gone from the crontab AND run by a workflow" do
    crontab = crontab()
    corpus = workflow_corpus()
    scheduled_workers = Enum.map(crontab, &elem(&1, 1))

    for {worker, invocation} <- @moved_duties do
      refute worker in scheduled_workers,
             "#{inspect(worker)} is back in the Oban crontab. It cannot be scheduled there: " <>
               "the node scales to zero and Oban's Cron plugin has no catch-up pass, so the " <>
               "entry fires only when something else wakes the machine in that minute. Its " <>
               "schedule lives in .github/workflows/."

      assert corpus =~ invocation,
             "#{inspect(worker)} was removed from the crontab, but no workflow invokes " <>
               "`#{invocation}`. That is not a fix — it turns \"runs when the machine happens " <>
               "to be awake\" into \"never runs\". Removal and replacement land together or " <>
               "neither lands."
    end
  end

  test "the crontab has not grown, and its remaining size is stated" do
    count = length(crontab())

    assert count <= @remaining_entries,
           "the Oban crontab has #{count} entries, up from #{@remaining_entries}. Every entry " <>
             "is unreliable for the reason above, so a new scheduled duty belongs in a " <>
             "workflow, not here. If a duty genuinely must run in-node, say why in config.exs " <>
             "and raise this number deliberately."

    # The mirror, so a wholesale deletion of the crontab does not read as
    # progress. Seventeen entries remain BECAUSE their disposition needs
    # evidence of which have ever run, and eight of them carry retention or
    # account-lifecycle duties — deleting those without replacements would stop
    # data-protection work that is currently at least intermittent.
    assert count == @remaining_entries,
           "the Oban crontab has #{count} entries, down from #{@remaining_entries}. If duties " <>
             "were moved to workflows, add them to @moved_duties so the pairing is checked. If " <>
             "they were simply deleted, that is the regression this file exists to catch."
  end
end
