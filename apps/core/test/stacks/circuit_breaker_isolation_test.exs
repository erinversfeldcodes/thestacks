defmodule Stacks.CircuitBreakerIsolationTest do
  @moduledoc """
      A fuse blown by one test must not be blown for the next.

      `:fuse` is global OTP state with no per-test ownership, so before
      `Core.DataCase.reset_circuit_breakers/0` existed, a melting test left its
      breaker open for everything that ran after it. The symptom was a
      one-in-four flake: `upload_telemetry_test.exs`'s
      `POST /api/books/:id/merge-format … returns 422` got **503** once in four
      full-suite runs and was green 3/3 in isolation — 503 being
      `Books.merge_edition/2` answering `:resolver_unavailable`, which is what
      it says when the ISBN resolver's breaker is open.

      ⚠️ The two tests below are deliberately SYMMETRIC: each asserts the fuse
      is closed on entry and then blows it. Whichever order ExUnit picks, the
      second one to run fails without the reset — so the assertion does not
      depend on a seed, which is the whole point given the original flake could
      not be pinned to one.

      `async: false` because the subject is a global: a concurrent test melting
      the same fuse would make this suite's own result depend on timing, which
      is the defect rather than the test for it.
  """

  use Core.DataCase, async: false

  alias Stacks.CircuitBreakers

  @fuse :open_library_fuse

  defp blow(fuse) do
    # The standard spec tolerates a few melts before opening; melting well past
    # it is what guarantees the fuse is OPEN rather than merely warm.
    CircuitBreakers.install_all()
    for _ <- 1..20, do: :fuse.melt(fuse)
    :ok
  end

  defp state(fuse) do
    case :fuse.ask(fuse, :sync) do
      :ok -> :closed
      :blown -> :blown
      {:error, :not_found} -> :absent
    end
  end

  test "A: the resolver fuse is closed on entry, then blown here" do
    assert state(@fuse) in [:closed, :absent],
           "#{@fuse} was already #{state(@fuse)} when this test started — a previous test left " <>
             "it open and Core.DataCase.reset_circuit_breakers/0 did not close it. That is the " <>
             "one-in-four 503 flake, reproduced."

    blow(@fuse)
    assert state(@fuse) == :blown, "the probe failed to blow the fuse, so test B proves nothing"
  end

  test "B: the resolver fuse is closed on entry, then blown here" do
    assert state(@fuse) in [:closed, :absent],
           "#{@fuse} was already #{state(@fuse)} when this test started — a previous test left " <>
             "it open and Core.DataCase.reset_circuit_breakers/0 did not close it. That is the " <>
             "one-in-four 503 flake, reproduced."

    blow(@fuse)
    assert state(@fuse) == :blown, "the probe failed to blow the fuse, so test A proves nothing"
  end

  test "the reset covers every managed fuse, not just the one above" do
    # A roster-derived reset is only as good as the roster, and `fuse_names/0`
    # is derived from `@fuses` — so this asserts the two have not drifted and
    # that reset actually closes each one.
    names = CircuitBreakers.fuse_names()

    assert length(names) >= 10,
           "expected the managed-fuse roster to hold at least ten breakers, got #{length(names)}"

    CircuitBreakers.install_all()
    for name <- names, _ <- 1..20, do: :fuse.melt(name)

    blown = Enum.filter(names, &(state(&1) == :blown))

    assert length(blown) == length(names),
           "not every fuse could be blown: #{inspect(names -- blown)}"

    Core.DataCase.reset_circuit_breakers()

    still_blown = Enum.filter(names, &(state(&1) == :blown))
    assert still_blown == [], "reset_circuit_breakers/0 left these open: #{inspect(still_blown)}"
  end
end
