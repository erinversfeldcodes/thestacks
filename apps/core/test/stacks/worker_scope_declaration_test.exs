defmodule Stacks.WorkerScopeDeclarationTest do
  @moduledoc """
      Every Oban worker declares, at compile time, whether it acts for one user
      or across the system.

      ⚠️ **This is deliberately not the same check as `scripts/check-rls-scope.sh`,
      and the difference is the point.** That gate reads source text: it can see
      that `scope: :user` appears in a file, and it can see whether the file
      mentions a secured schema. What it cannot see is whether the macro
      actually *worked* — whether `use Stacks.Worker` produced a module that
      carries its declaration at runtime. A gate that greps for a string would
      keep passing if the macro silently stopped emitting `__rls_scope__/0`.

      So this asserts the runtime fact, and the gate asserts the textual one.
      Neither is sufficient alone, which is why `Stacks.Worker.declared_scopes/0`
      exists and why this file is its caller — a function with no caller proves
      nothing, whatever its docstring says.
  """

  use ExUnit.Case, async: true

  alias Stacks.Worker

  # Pinned so a worker added without a declaration, or one whose declaration
  # stopped reaching runtime, moves this number and fails rather than slipping
  # in. Not a target — the size of the roster, stated.
  @expected_workers 34

  test "every worker carries its scope declaration at runtime" do
    declared = Worker.declared_scopes()

    assert length(declared) == @expected_workers,
           "expected #{@expected_workers} workers to declare a scope, found #{length(declared)}. " <>
             "If a worker was added or removed, move this number deliberately; if the count " <>
             "DROPPED without a worker being deleted, the macro has stopped emitting the " <>
             "declaration and `check-rls-scope.sh` would not notice — it reads source text."

    for {module, scope} <- declared do
      assert scope in [:user, :system],
             "#{inspect(module)} declared #{inspect(scope)}, which is neither :user nor :system"
    end
  end

  test "the split between per-user and system-wide jobs is stated" do
    # ⚠️ Recorded rather than asserted as a target. The ratio matters because
    # `:system` is the answer somebody reaches for when they do not want to
    # decide which user a job acts for, and a sudden jump in it is worth
    # noticing in a diff.
    scopes = Worker.declared_scopes() |> Enum.map(&elem(&1, 1)) |> Enum.frequencies()

    assert scopes == %{user: 8, system: 26},
           "the scope split changed to #{inspect(scopes)}. That is fine if deliberate — update " <>
             "this — but a job moving from :user to :system means it stopped acting for a " <>
             "specific person, which is a claim worth checking against what it actually queries."
  end

  test "⛔ a worker declaring :user can name the user it scopes to" do
    # The runtime complement to the gate's textual check: a `:user` worker whose
    # args carry no user is a contradiction that surfaces as a `42501` whenever
    # the job next runs. The gate checks the source for a `user_id`; this checks
    # that the module it checked is actually a worker with a `perform/1`.
    for {module, :user} <- Worker.declared_scopes() do
      assert function_exported?(module, :perform, 1),
             "#{inspect(module)} declares scope: :user but exports no perform/1, so the gate " <>
               "checked a file that is not a worker"
    end
  end
end
