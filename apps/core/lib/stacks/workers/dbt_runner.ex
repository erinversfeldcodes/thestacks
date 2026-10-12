defmodule Stacks.Workers.DbtRunner do
  @moduledoc """
      Shells out to dbt.

      ⛔ It checks WHICH dbt first. `System.cmd("dbt", …)` runs whatever answers
      on PATH, and there are two programs by that name: dbt-core, which runs the
      models in this repository against the configured profile, and the dbt
      Cloud CLI, which forwards the invocation to a dbt Cloud account and takes
      a different argv. Installing the wrong one does not fail loudly — it fails
      as a confusing argument error, or worse, succeeds against something that
      is not this database.
  """

  @behaviour Stacks.Workers.DbtRunnerBehaviour

  @default_dbt_dir Path.expand("../../../../../dbt", __DIR__)

  @impl true
  def run(args) do
    with :ok <- verify_edition() do
      case System.cmd("dbt", args, cd: dbt_dir(), stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _} -> {:error, output}
      end
    end
  end

  @doc """
      Whether `dbt --version` output describes dbt-core rather than the Cloud CLI.

      dbt-core reports an installed Core version and its adapter plugins:

          Core:
            - installed: 1.12.2
          Plugins:
            - postgres: 1.11.0

      The Cloud CLI names itself instead, and reports no plugins — it has no
      local adapter, because the run happens elsewhere.
  """
  @spec core_edition?(String.t()) :: boolean()
  def core_edition?(version_output) do
    String.contains?(version_output, "Core:") and
      String.contains?(version_output, "installed:") and
      not String.contains?(version_output, "Cloud CLI")
  end

  defp verify_edition do
    case System.cmd("dbt", ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        if core_edition?(output) do
          :ok
        else
          {:error,
           "the `dbt` on PATH is not dbt-core — it reported:\n\n" <>
             output <>
             "\nThis project's models run against the local profile, which the " <>
             "dbt Cloud CLI does not do: it forwards to a dbt Cloud account and " <>
             "takes a different argv. Install dbt-core (the repo pins it in " <>
             ".venv-tools) or put it ahead of the Cloud CLI on PATH."}
        end

      {output, _} ->
        {:error, "could not determine the dbt edition; `dbt --version` failed:\n\n" <> output}
    end
  end

  @doc false
  def dbt_dir do
    Application.get_env(:core, :dbt_dir, @default_dbt_dir)
  end
end
