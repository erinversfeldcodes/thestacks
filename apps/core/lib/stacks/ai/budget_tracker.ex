defmodule Stacks.AI.BudgetTracker do
  @moduledoc """
  GenServer that tracks daily and monthly AI API spend per provider.
  Resets the daily counter at midnight UTC. Monthly limit is also enforced.

  Budget limits are read from application config:
    config :core, :ai_budget,
      daily_limit_cents: 5_00,    # $5/day
      monthly_limit_cents: 50_00  # $50/month
  """

  use GenServer

  require Logger

  @default_daily_limit_cents 500
  @default_monthly_limit_cents 5_000

  defstruct providers: %{}, daily_total_cents: 0, monthly_total_cents: 0

  # Client API

  @doc "Starts the BudgetTracker GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Records an AI API cost in cents for a given provider."
  @spec record_cost(atom() | String.t(), non_neg_integer()) :: :ok
  def record_cost(provider, cost_cents) when is_integer(cost_cents) and cost_cents >= 0 do
    GenServer.cast(__MODULE__, {:record_cost, provider, cost_cents})
  end

  @doc """
  Checks whether spending is within budget.
  Returns `:ok` or `{:error, :daily_limit_exceeded | :monthly_limit_exceeded}`.
  """
  @spec check_budget(atom() | String.t()) :: :ok | {:error, atom()}
  def check_budget(provider) do
    GenServer.call(__MODULE__, {:check_budget, provider})
  end

  @doc "Returns current spend state (for observability)."
  @spec current_state() :: map()
  def current_state do
    GenServer.call(__MODULE__, :current_state)
  end

  # Server callbacks

  @impl true
  def init(:ok) do
    schedule_midnight_reset()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:record_cost, provider, cost_cents}, state) do
    provider_key = to_string(provider)

    :telemetry.execute(
      [:stacks, :budget, :cost_recorded],
      %{amount_cents: cost_cents},
      %{provider: provider_key}
    )

    providers =
      Map.update(state.providers, provider_key, cost_cents, &(&1 + cost_cents))

    new_state = %{
      state
      | providers: providers,
        daily_total_cents: state.daily_total_cents + cost_cents,
        monthly_total_cents: state.monthly_total_cents + cost_cents
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_call({:check_budget, provider}, _from, state) do
    daily_limit = get_limit(:daily_limit_cents, @default_daily_limit_cents)
    monthly_limit = get_limit(:monthly_limit_cents, @default_monthly_limit_cents)

    result =
      cond do
        state.monthly_total_cents >= monthly_limit ->
          :telemetry.execute(
            [:stacks, :budget, :limit_exceeded],
            %{},
            %{provider: to_string(provider), type: :monthly}
          )

          {:error, :monthly_limit_exceeded}

        state.daily_total_cents >= daily_limit ->
          :telemetry.execute(
            [:stacks, :budget, :limit_exceeded],
            %{},
            %{provider: to_string(provider), type: :daily}
          )

          {:error, :daily_limit_exceeded}

        true ->
          :ok
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:current_state, _from, state) do
    {:reply,
     %{
       daily_total_cents: state.daily_total_cents,
       monthly_total_cents: state.monthly_total_cents,
       providers: state.providers
     }, state}
  end

  @impl true
  def handle_info(:reset_daily, state) do
    Logger.info("BudgetTracker: resetting daily AI spend counters")
    schedule_midnight_reset()
    {:noreply, %{state | daily_total_cents: 0, providers: %{}}}
  end

  defp schedule_midnight_reset do
    now = DateTime.utc_now()

    tomorrow_midnight =
      now |> DateTime.to_date() |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    ms_until_midnight = DateTime.diff(tomorrow_midnight, now, :millisecond)
    Process.send_after(self(), :reset_daily, ms_until_midnight)
  end

  defp get_limit(key, default) do
    :core
    |> Application.get_env(:ai_budget, [])
    |> Keyword.get(key, default)
  end
end
