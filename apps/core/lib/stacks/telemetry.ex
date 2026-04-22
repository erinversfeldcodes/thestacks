defmodule Stacks.Telemetry do
  @moduledoc """
  Thin wrappers around `:telemetry.span/3` for profiling named phases
  of the upload pipeline.

  Call `phase/3` around any chunk of code you want to time:

      Stacks.Telemetry.phase(:isbn_resolution, %{upload_id: upload_id}, fn ->
        Moderation.resolve_and_store_all(candidates, user_id)
      end)

  This emits:

    * `[:stacks, :upload, :phase, :start]`
    * `[:stacks, :upload, :phase, :stop]`  with `%{duration: native_time}`
    * `[:stacks, :upload, :phase, :exception]` on crash

  all tagged with `%{phase: :isbn_resolution, upload_id: ...}`.
  `Stacks.Telemetry.Reporter` subscribes to these events and writes a
  structured log line per `:stop`, suitable for greppable analysis of
  where time is going in a given deploy window.
  """

  @doc """
  Run `fun` inside a phase span. Returns whatever `fun` returns.
  """
  @spec phase(atom(), map(), (-> result)) :: result when result: var
  def phase(phase, metadata \\ %{}, fun)
      when is_atom(phase) and is_map(metadata) and is_function(fun, 0) do
    :telemetry.span(
      [:stacks, :upload, :phase],
      Map.put(metadata, :phase, phase),
      fn -> {fun.(), %{}} end
    )
  end
end
