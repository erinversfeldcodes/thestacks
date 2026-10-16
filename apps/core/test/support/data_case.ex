defmodule Core.DataCase do
  @moduledoc """
      This module defines the setup for tests requiring
      access to the application's data layer.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Core.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Core.DataCase
    end
  end

  setup tags do
    Core.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    alias Ecto.Adapters.SQL.Sandbox
    pid = Sandbox.start_owner!(Core.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    reset_circuit_breakers()
  end

  @doc """
      Close every managed circuit breaker before the test runs.

      ⚠️ `:fuse` is global OTP state with no per-test ownership, so a fuse one
      test blows stays blown for everything that runs after it in the same run.
      The symptom was a one-in-four flake: `upload_telemetry_test.exs`'s
      `POST /api/books/:id/merge-format … returns 422` got **503** once in four
      full-suite runs, green 3/3 in isolation. 503 is
      `Books.merge_edition/2` reporting `:resolver_unavailable`, which is what
      it says when the ISBN resolver's breaker is open — so the assertion was
      never the problem; an earlier test was. `circuit_breakers_test.exs` alone
      melts 30 times and resets twice.

      Reset here rather than in the failing test, because the failing test is
      whichever one happens to run after a melting one — a per-test fix would
      move the flake rather than remove it. Same family as a metrics registry
      accumulating across a run: a shared global that nothing resets.

      ⚠️ NOT reproduced as a specific interleaving. Pairing the prime suspect
      with the failing file across three seeds stayed green, so the culprit was
      not identified by seed hunting and this closes the CLASS instead. The
      accompanying test proves the reset works regardless of order, which is the
      property that makes the interleaving stop mattering.
  """
  def reset_circuit_breakers do
    for name <- Stacks.CircuitBreakers.fuse_names() do
      # `:fuse.reset/1` answers `{:error, :not_found}` for a fuse that was never
      # installed, which is the normal state in a test run that has not touched
      # it. Not an error, and not worth branching on.
      :fuse.reset(name)
    end

    :ok
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
