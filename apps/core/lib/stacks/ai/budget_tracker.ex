defmodule Stacks.AI.BudgetTracker do
  @moduledoc """
      GenServer that tracks daily and monthly AI API spend per provider.
      Resets the daily counter at midnight UTC. Monthly limit is also enforced.

      Budget limits are read from application config:
        config:core,:ai_budget,
          daily_limit_cents: 5_00,    # $5/day
          monthly_limit_cents: 50_00  # $50/month
  """

  use GenServer

  alias Stacks.AI.Spend

  require Logger

  # The providers this tracker actually meters. Production has exactly one
  # caller — `Stacks.AI.Client` passing `:modal` — and this list says so rather
  # than implying a vocabulary that does not exist.
  #
  # ⚠️ `provider` reaches a metric LABEL, and it arrives as whatever atom a
  # caller passed: `to_string/1` on caller input is unbounded by construction,
  # however disciplined today's single caller is. The spend STATE below keeps
  # the exact key, because that is the ledger and it must stay accurate for a
  # provider nobody declared; only the label collapses to "other".
  #
  # Adding a metered provider means adding it here, and an "other" series
  # appearing in the store is the signal that someone did not. That is the
  # intended failure mode: visible under-labelling beats an unbounded label set
  # on a metric that meters money.
  @telemetry_providers ~w(modal)

  @default_daily_limit_cents 500
  @default_monthly_limit_cents 5_000

  defstruct providers: %{}, daily_total_cents: 0, monthly_total_cents: 0

  @doc "Starts the BudgetTracker GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Records an AI API cost in cents for a given provider."
  @spec record_cost(atom() | String.t(), non_neg_integer()) :: :ok
  def record_cost(provider, cost_cents) when is_integer(cost_cents) and cost_cents >= 0 do
    # ⛔ THE LEDGER IS WRITTEN HERE, IN THE CALLER'S PROCESS, AND NOT IN THE
    # GenServer BELOW.
    #
    # Two reasons, and the second is the stronger. A `cast` is fire-and-forget,
    # so a ledger write inside it is lost silently if the process is busy,
    # restarting or gone — and this is the record that decides whether the next
    # request is allowed. The caller has just spent the money; the durable note
    # of it should not depend on a mailbox.
    #
    # ⚖️ It also keeps the write inside whatever transaction or sandbox the
    # caller is in, which a separate process cannot join.
    Spend.record(provider, cost_cents)

    # ⚠️ Best-effort, and allowed to find nobody home. Since the decision moved
    # to the ledger, this cast feeds telemetry and an in-memory view — useful,
    # and not something a charge should depend on. `GenServer.cast/2` to an
    # unregistered name raises, so the lookup is explicit.
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:record_cost, provider, cost_cents})
    end

    :ok
  end

  @doc """
      Checks whether spending is within budget.
      Returns `:ok` or `{:error,:daily_limit_exceeded |:monthly_limit_exceeded}`.
  """
  @spec check_budget(atom() | String.t()) :: :ok | {:error, atom()}
  def check_budget(provider) do
    daily_limit = get_limit(:daily_limit_cents, @default_daily_limit_cents)
    monthly_limit = get_limit(:monthly_limit_cents, @default_monthly_limit_cents)

    # ⛔ ANSWERED FROM THE LEDGER, NOT FROM PROCESS STATE, AND NOT THROUGH THE
    # GenServer AT ALL.
    #
    # This used to ask the tracker for its in-memory totals. A freshly woken
    # node has an empty struct and a full day's spend behind it, so the answer
    # was "plenty of budget" every time the machine had been idle — which on a
    # scale-to-zero host is most mornings.
    #
    # ⚖️ Once the spend is durable, a process holding a second copy of it is
    # not a cache, it is a disagreement waiting to happen. The decision belongs
    # where the fact is.
    #
    # ⚠️ Per-provider, where the struct's totals were global: a single shared
    # ceiling meant one provider's spend refused another's requests, which is
    # not what a per-provider budget means.
    cond do
      Spend.spent(provider, :monthly) >= monthly_limit ->
        :telemetry.execute(
          [:stacks, :budget, :limit_exceeded],
          %{},
          %{provider: bounded_provider(provider), type: :monthly}
        )

        {:error, :monthly_limit_exceeded}

      Spend.spent(provider, :daily) >= daily_limit ->
        :telemetry.execute(
          [:stacks, :budget, :limit_exceeded],
          %{},
          %{provider: bounded_provider(provider), type: :daily}
        )

        {:error, :daily_limit_exceeded}

      true ->
        :ok
    end
  end

  @doc "Returns current spend state (for observability)."
  @spec current_state() :: map()
  def current_state do
    GenServer.call(__MODULE__, :current_state)
  end

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
      %{provider: bounded_provider(provider_key)}
    )

    # ⛔ THE DURABLE LEDGER IS THE RECORD; THE STRUCT IS A CACHE OF IT.
    #
    # These totals used to live only here, and this process dies with the node.
    # On a machine that scales to zero that made the budget resettable by
    # idling: the ceiling came back when traffic stopped, nothing said so, and
    # the only way to exceed a daily cap was to stay busy enough to stay alive.
    #
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

  @doc "The provider values the budget metrics may label. Anything else labels as `other`."
  @spec telemetry_providers() :: [String.t()]
  def telemetry_providers, do: @telemetry_providers

  defp bounded_provider(provider) do
    key = to_string(provider)
    if key in @telemetry_providers, do: key, else: "other"
  end

  defp get_limit(key, default) do
    :core
    |> Application.get_env(:ai_budget, [])
    |> Keyword.get(key, default)
  end
end
