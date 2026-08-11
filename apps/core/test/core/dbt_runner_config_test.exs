defmodule Core.DbtRunnerConfigTest do
  @moduledoc """
  Drift guard for `DbtRunner.dbt_dir/0` (282): a cwd-relative default
  (`../../dbt`) worked under `mix test` (cwd = apps/core) but broke under
  `just dev` (cwd = repo root), failing every `DbtRefreshJob`. Asserts the
  resolved dir is anchored to the repo root regardless of cwd.
  """

  use ExUnit.Case, async: false

  alias Stacks.Workers.DbtRunner

  test "resolves a real dbt project directory independent of the process cwd" do
    neutral = System.tmp_dir!()
    dir = File.cd!(neutral, fn -> DbtRunner.dbt_dir() end)

    assert is_binary(dir), "DbtRunner.dbt_dir/0 did not resolve to a path: #{inspect(dir)}"

    assert File.dir?(dir),
           "DbtRunner.dbt_dir/0 resolved to a nonexistent directory when cwd was #{neutral}: " <>
             "#{dir} (regression of Issue #282 — cwd-relative File.cwd!() default?)"

    assert File.exists?(Path.join(dir, "dbt_project.yml")),
           "resolved dbt_dir exists but has no dbt_project.yml: #{dir}"
  end
end
