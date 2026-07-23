defmodule Stacks.Workers.DbtRunner do
  @moduledoc false

  @behaviour Stacks.Workers.DbtRunnerBehaviour

  # The dbt project lives at the umbrella root (`<repo>/dbt`). Anchor the
  # default to this module's compiled source location rather than `File.cwd!()`:
  # dev starts `mix phx.server` (`just dev`) from the repo root, where a
  # cwd-relative `../../dbt` resolves to a nonexistent path and every
  # event-triggered `DbtRefreshJob` fails with `Could not cd` (Issue #282).
  # This module sits at `apps/core/lib/stacks/workers`, so the repo root is five
  # levels up. `:dbt_dir` config still overrides. Releases don't ship `dbt/`
  # (see `deploy/Dockerfile.core`), so this default only takes effect in dev.
  @default_dbt_dir Path.expand("../../../../../dbt", __DIR__)

  @impl true
  def run(args) do
    case System.cmd("dbt", args, cd: dbt_dir(), stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  end

  @doc false
  def dbt_dir do
    Application.get_env(:core, :dbt_dir, @default_dbt_dir)
  end
end
