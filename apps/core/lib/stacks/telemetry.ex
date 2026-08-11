defmodule Stacks.Telemetry do
  @moduledoc """
  Thin wrappers around `:telemetry.span/3` for timing upload-pipeline
  phases. `phase/3` emits `[:stacks, :upload, :phase, :start | :stop |
  :exception]` tagged with `%{phase:, upload_id:}`;
  `Stacks.Telemetry.Reporter` turns each `:stop` into a greppable
  structured log line.

      Stacks.Telemetry.phase(:isbn_resolution, %{upload_id: id}, fn ->
        Moderation.resolve_and_store_all(candidates, user_id)
      end)
  """

  @doc """
  Run `fun` inside a phase span. Returns whatever `fun` returns.
  """
  @spec phase(atom(), map(), (-> result)) :: result when result: var
  def phase(phase, metadata \\ %{}, fun)
      when is_atom(phase) and is_map(metadata) and is_function(fun, 0) do
    full_metadata = Map.put(metadata, :phase, phase)

    :telemetry.span(
      [:stacks, :upload, :phase],
      full_metadata,
      fn -> {fun.(), full_metadata} end
    )
  end
end
