defmodule Stacks.Workers.DbtRunnerBehaviour do
  @moduledoc false

  @callback run(args :: [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
end
