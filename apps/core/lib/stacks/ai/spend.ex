defmodule Stacks.AI.Spend do
  @moduledoc """
      What an AI provider has cost us this period, as a durable fact.

      ⛔ THIS EXISTS BECAUSE THE BUDGET USED TO RESET WHENEVER THE MACHINE
      IDLED. `Stacks.AI.BudgetTracker` holds its totals in GenServer state and
      references `Repo` nowhere — so on a node that scales to zero, the ceiling
      was restored by going quiet, the restore was invisible, and the only way
      to exceed a daily cap was to stay busy enough to keep the node alive.

      ⚠️ Its daily reset had the same shape: `schedule_midnight_reset/0` sends
      itself a message at midnight, which arrives only if the process is there
      at midnight. A machine asleep from 23:00 never resets, and never needed
      to, having already lost the count.

      ⚖️ READING IS A QUERY WITH A DATE IN IT. "Today's spend" asks the
      database what today holds, which is correct whether the node has been up
      for a month or ten seconds — rather than asking a counter whose accuracy
      depends on an uptime nobody promised.
  """
  use Ecto.Schema

  import Ecto.Query

  alias Core.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]
  @type t :: %__MODULE__{}

  schema "ai_spend" do
    field :provider, :string
    field :period, :string
    field :period_start, :date
    field :spend_cents, :integer

    timestamps()
  end

  @doc """
      Add a cost to this provider's running totals, for both periods.

      ⛔ ONE STATEMENT PER PERIOD, UPSERTED, AND THE ATOMICITY IS THE POINT. A
      read-then-write would lose a concurrent charge — two jobs billing at once
      would each read the same total and each write their own, and the cheaper
      of the two would vanish. `ON CONFLICT … spend_cents = ai_spend.spend_cents
      + EXCLUDED.spend_cents` adds inside the database, where the unique index
      serialises it.

      ⚠️ Returns `:ok` regardless: metering must not fail the work it meters.
      The caller has already spent the money by the time this runs, and a
      failure to record it is a reporting problem, not a reason to discard the
      result the reader is waiting for.
  """
  @spec record(String.t() | atom(), non_neg_integer(), Date.t()) :: :ok
  def record(provider, cents, today \\ Date.utc_today())

  def record(_provider, 0, _today), do: :ok

  def record(provider, cents, today) when is_integer(cents) and cents > 0 do
    provider = to_string(provider)

    for {period, start} <- [{"daily", today}, {"monthly", Date.beginning_of_month(today)}] do
      Repo.insert_all(
        __MODULE__,
        [
          %{
            id: Ecto.UUID.generate(),
            provider: provider,
            period: period,
            period_start: start,
            spend_cents: cents,
            created_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        ],
        on_conflict: [inc: [spend_cents: cents]],
        conflict_target: [:provider, :period, :period_start]
      )
    end

    :ok
  end

  @doc """
      What this provider has cost in the named period.

      ⚖️ Answers 0 for a period with no row, which is the same answer as a
      period with no spend — correctly, because they are the same thing. The
      distinction that matters is kept elsewhere: a row exists once money has
      been spent, and `#{inspect(__MODULE__)}` never writes a zero.
  """
  @spec spent(String.t() | atom(), :daily | :monthly, Date.t()) :: non_neg_integer()
  def spent(provider, period, today \\ Date.utc_today())

  def spent(provider, :daily, today), do: lookup(provider, "daily", today)

  def spent(provider, :monthly, today),
    do: lookup(provider, "monthly", Date.beginning_of_month(today))

  defp lookup(provider, period, start) do
    provider = to_string(provider)

    __MODULE__
    |> where([s], s.provider == ^provider and s.period == ^period and s.period_start == ^start)
    |> select([s], s.spend_cents)
    |> Repo.one()
    |> case do
      nil -> 0
      cents -> cents
    end
  end
end
