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

  require Logger

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
    field :spend_micro_cents, :integer

    timestamps()
  end

  @doc """
      Add a cost, IN MICRO-CENTS, to this provider's running totals.

      ⛔ MICRO-CENTS, NOT CENTS, AND THE UNIT IS THE POINT. Token pricing is
      quoted per million, so a 400-token completion costs ~0.035¢ — a quantity a
      cent cannot express. Charging it in cents meant rounding up to one, which
      over-charged an ordinary call by roughly 28× while a large call was
      under-charged by up to 4.4× at the old rate. Micro-cents removes the
      rounding by construction; there is nothing left to round.

      ⛔ ONE STATEMENT PER PERIOD, UPSERTED, AND THE ATOMICITY IS THE POINT. A
      read-then-write would lose a concurrent charge — two jobs billing at once
      would each read the same total and each write their own, and the cheaper
      of the two would vanish. `ON CONFLICT … spend_micro_cents =
      ai_spend.spend_micro_cents + EXCLUDED.spend_micro_cents` adds inside the database, where the unique index
      serialises it.

      ⚠️ METERING MUST NOT FAIL THE WORK IT METERS, AND NOW IT CANNOT. The
      caller has already spent the money by the time this runs, so a failure to
      record it is a reporting problem — not a reason to discard the result the
      reader is waiting for.

      ⛔ This used to be a promise the code did not keep. There was no `rescue`,
      so a `Repo` error raised out of `TogetherClient.parse_success_response/1`,
      crashed the worker, and Oban retried the job — **calling and paying for
      the completion a second time**. A metering failure costing a second
      charge is the exact opposite of what this docstring claimed.

      ⚖️ The cost of catching it is stated rather than hidden: during a database
      outage the budget UNDER-COUNTS, so the ceiling is too generous for as long
      as the outage lasts. That is the better of the two failures — the
      alternative bills twice for the same answer.
  """
  @spec record(String.t() | atom(), non_neg_integer(), Date.t()) :: :ok
  def record(provider, micro_cents, today \\ Date.utc_today())

  def record(_provider, 0, _today), do: :ok

  def record(provider, micro_cents, today) when is_integer(micro_cents) and micro_cents > 0 do
    provider = to_string(provider)

    try do
      upsert_both_periods(provider, micro_cents, today)
    rescue
      error ->
        # ⚠️ Logged at error, because an unrecorded charge is money spent with
        # no trace of it — invisible in the ledger, the gauge and the panel.
        Logger.error(
          "Spend.record: could not record #{micro_cents} micro-cents for #{provider}: " <>
            Exception.message(error)
        )
    end

    :ok
  end

  defp upsert_both_periods(provider, micro_cents, today) do
    for {period, start} <- [{"daily", today}, {"monthly", Date.beginning_of_month(today)}] do
      Repo.insert_all(
        __MODULE__,
        [
          %{
            id: Ecto.UUID.generate(),
            provider: provider,
            period: period,
            period_start: start,
            spend_micro_cents: micro_cents,
            created_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        ],
        on_conflict: [inc: [spend_micro_cents: micro_cents]],
        conflict_target: [:provider, :period, :period_start]
      )
    end
  end

  @doc """
      What this provider has cost in the named period, in MICRO-CENTS.

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
    |> select([s], s.spend_micro_cents)
    |> Repo.one()
    |> case do
      nil -> 0
      micro_cents -> micro_cents
    end
  end
end
