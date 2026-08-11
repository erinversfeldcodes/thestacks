defmodule Core.DbtRunnerConfigTest do
  @moduledoc """
  Drift guard for `DbtRunner`'s dbt project directory (Issue #282).

  `DbtRunner.dbt_dir/0` once defaulted to `Path.join(File.cwd!(), "../../dbt")`,
  which assumes the BEAM's cwd is `apps/core`. Dev starts `mix phx.server`
  (`just dev`) from the repo root, so the default resolved to `<repo>/../../dbt`
  — a nonexistent path — and every event-triggered `DbtRefreshJob` failed with
  `spawn: Could not cd to …/../../dbt`. Sibling of the #278 watcher-cwd defect.

  `mix test` happens to run each umbrella app with cwd = `apps/core`, where the
  broken `File.cwd!()` default *coincidentally* resolves to `<repo>/dbt` — so a
  test that trusts the ambient cwd can't catch the bug. This test instead
  resolves `dbt_dir/0` from a neutral cwd and asserts it still points at a real
  dbt project directory: it fails against the cwd-relative default and passes
  only when the default is anchored to the module's source location, cwd-free.

  It is `async: false` because it briefly changes the process working directory
  (`File.cd!/2` restores it on the way out, including on failure).
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
