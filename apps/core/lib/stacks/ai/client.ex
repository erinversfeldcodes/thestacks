defmodule Stacks.AI.Client do
  @moduledoc """
  HTTP client for calling the vision sidecar.

  The actual implementation is swappable via Application env:
    config :core, :vision_client, Stacks.AI.Client      # real HTTP client
    config :core, :vision_client, Stacks.AI.MockClient  # for tests

  All callers go through `call_vision/2`, which delegates to the configured module.
  """

  @behaviour Stacks.AI.ClientBehaviour

  @fuse_name :vision_sidecar

  @impl true
  def call_vision(endpoint, payload) do
    configured_client().call_vision(endpoint, payload)
  end

  @doc false
  def do_call_vision(endpoint, payload) do
    with :ok <- Stacks.AI.BudgetTracker.check_budget(:together_ai) do
      :fuse.ask(@fuse_name, :sync)
      |> case do
        :ok -> make_vision_request(endpoint, payload)
        :blown -> {:error, :circuit_open}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp make_vision_request(endpoint, payload) do
    base_url = Application.get_env(:core, :vision_sidecar_url, "http://localhost:8000")
    url = "#{base_url}/#{endpoint}"

    body = Jason.encode!(payload)

    req =
      Finch.build(
        :post,
        url,
        [{"content-type", "application/json"}],
        body
      )

    case Finch.request(req, Stacks.Finch) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        Jason.decode(resp_body)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        :fuse.melt(@fuse_name)
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        :fuse.melt(@fuse_name)
        {:error, reason}
    end
  end

  defp configured_client do
    Application.get_env(:core, :vision_client, __MODULE__)
  end
end
