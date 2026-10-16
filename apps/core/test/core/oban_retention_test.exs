defmodule Core.ObanRetentionTest do
  @moduledoc """
      How long a finished Oban job row survives, and why that is a correctness
      question rather than a housekeeping one.

      `Oban.Plugins.Pruner` defaults to `max_age: 60` — sixty SECONDS. Under
      that default a completed job row is deleted a minute after it finishes,
      so `oban_jobs` reads empty on every stack at all times.

      ⚠️ The consequence is not "we lose some history". It is that **"did the
      nightly job run?" becomes unanswerable**, and the two states an operator
      most needs to tell apart — "ran and was pruned" and "never ran" — produce
      byte-identical evidence. This app's crontab fires 20 jobs on a machine
      configured to scale to zero, where a missed run is the expected failure,
      and two runbook steps send the reader to `oban_jobs` to check.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)

  # The floor, not the configured value. A test pinning the exact number would
  # fail on a deliberate raise, which is the wrong way round: the invariant is
  # "long enough to answer the question", and longer is never worse.
  @minimum_seconds 7 * 24 * 60 * 60

  defp pruner_opts do
    :core
    |> Application.get_env(Oban)
    |> Keyword.fetch!(:plugins)
    |> Enum.find_value(fn
      {Oban.Plugins.Pruner, opts} -> opts
      Oban.Plugins.Pruner -> :bare
      _ -> nil
    end)
  end

  test "the pruner keeps finished jobs for at least a week" do
    opts = pruner_opts()

    refute opts == :bare,
           "`Oban.Plugins.Pruner` is configured bare, so it uses the library default of 60 " <>
             "SECONDS. Job history is then destroyed a minute after it is written, `oban_jobs` " <>
             "reads empty on every stack, and \"did the nightly job run?\" has no answer in the " <>
             "database — \"ran and was pruned\" and \"never ran\" look identical."

    refute is_nil(opts), "`Oban.Plugins.Pruner` is not in the plugin list at all"

    max_age = Keyword.fetch!(opts, :max_age)
    seconds = Oban.Period.to_seconds(max_age)

    assert seconds >= @minimum_seconds,
           "the pruner keeps finished jobs for #{seconds}s (#{inspect(max_age)}), which is " <>
             "under the #{@minimum_seconds}s floor. The crontab has weekly entries, so a window " <>
             "shorter than a week cannot show whether the last one ran."
  end

  test "no uniqueness period exceeds the pruner window" do
    # ⚠️ The half of "is this safe?" that the engine test below does NOT cover,
    # and that the first version of this change argued past.
    #
    # Oban's uniqueness checks READ retained rows: `@unique_defaults` carries
    # `states: :successful`, which includes `completed`. So a `unique:` period
    # longer than `max_age` is silently truncated to the pruner window — the
    # rows it would match have already been deleted. Every one of this app's
    # nine declarations was in that state at 60 seconds.
    #
    # The relationship is what matters, not the numbers: a dedupe window can
    # never outlive the evidence it depends on. This fails if someone lowers
    # `max_age` below a declared period, which would quietly shorten a dedupe
    # somebody is relying on.
    max_age = Oban.Period.to_seconds(Keyword.fetch!(pruner_opts(), :max_age))

    declared =
      Path.join(@repo_root, "apps/core/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        source = File.read!(file)

        for [_, period] <- Regex.scan(~r/unique:\s*\[[^\]]*period:\s*([0-9_]+)/s, source) do
          {Path.relative_to(file, @repo_root), String.to_integer(String.replace(period, "_", ""))}
        end
      end)

    refute declared == [],
           "no `unique:` declarations were found — the scan is matching nothing, so this test " <>
             "is passing vacuously rather than because the periods are safe"

    truncated = for {file, period} <- declared, period > max_age, do: {file, period}

    assert truncated == [],
           "these uniqueness periods outlive the pruner window (#{max_age}s), so Oban will " <>
             "find no retained row to match against and the dedupe is silently cut short: " <>
             "#{inspect(truncated)}"
  end

  test "the pruner only deletes terminal rows, which is why a longer window is free" do
    # The reason raising `max_age` is safe, asserted rather than assumed. If
    # pruning touched `available` or `retryable`, a longer window would MASK a
    # growing backlog instead of revealing it, and the test above would be
    # arguing for the wrong thing.
    #
    # ⚠️ Reads the ENGINE, not the plugin. The plugin holds the schedule and
    # the options; the state list that decides what actually gets deleted is in
    # `Oban.Engines.Basic.prune_jobs/3`. The first version of this test read
    # the plugin and failed — correctly, and usefully: it was looking for a
    # guarantee in a file that does not make it.
    source = File.read!(Path.join(@repo_root, "deps/oban/lib/oban/engines/basic.ex"))

    [prune_body] = Regex.run(~r/def prune_jobs\(.*?\n  end/s, source)

    for state <- ~w(completed cancelled discarded) do
      assert prune_body =~ ~s|"#{state}"|,
             "`prune_jobs/3` no longer prunes #{state} rows; re-read it before trusting that a " <>
               "longer max_age is free"
    end

    for unfinished <- ~w(available retryable scheduled executing) do
      refute prune_body =~ ~s|"#{unfinished}"|,
             "`prune_jobs/3` now deletes #{unfinished} rows. A longer max_age is only safe " <>
               "while pruning is confined to terminal states — reaching unfinished work means " <>
               "raising the window HIDES a backlog rather than exposing one."
    end
  end
end
