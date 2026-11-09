defmodule Stacks.AI.Budget do
  @moduledoc """
      The ceiling on AI API spend, per provider, per period.

      ⛔ THIS USED TO BE A GenServer WHOSE TOTALS DIED WITH THE NODE, and that
      was the defect rather than a detail of it: on a host that scales to zero
      the budget was restored by going quiet, invisibly, and the only way to
      exceed a daily cap was to stay busy enough to stay alive. Its midnight
      reset had the same shape — a message that arrived only if the process was
      there to receive it.

      ⚖️ The spend now lives in `Stacks.AI.Spend`, a row per provider per
      period, so both functions here are plain calls against a durable fact.
      There is no process: a second copy of the spend is not a cache, it is a
      disagreement waiting to happen.

      ⚠️ The ledger is denominated in MICRO-CENTS, because token pricing is
      quoted per million and a cent cannot express the cost of a short
      completion. Limits stay in cents — a ceiling is a human decision, written
      in the unit a person would write it in — and are converted once, at the
      comparison.

      Budget limits are read from application config:

          config :core, :ai_budget,
            daily_limit_cents: 500,
            monthly_limit_cents: 5_000
  """

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
  # ⚠️ `together` was missing, and the gauge this issue added labelled it
  # `"other"` — on the one provider the work exists to meter. Because the
  # series is a `last_value` keyed on `provider`, a second undeclared provider
  # would ALIAS rather than merely mislabel, and the dashboard legend would read
  # "today — other". The comment below names that failure mode; declaring the
  # provider is what acts on it.
  @telemetry_providers ~w(modal together)

  @micro_cents_per_cent 100_000

  @default_daily_limit_cents 500
  @default_monthly_limit_cents 5_000

  @doc """
      Record an AI API cost, in MICRO-CENTS, against a provider.

      ⛔ WRITTEN SYNCHRONOUSLY, WHERE IT USED TO BE A `cast` TO A GenServer.
      A cast is fire-and-forget, so a ledger write inside one is lost silently
      if the process is busy, restarting or gone — and this is the record that
      decides whether the next request is allowed. The caller has just spent the
      money; the durable note
      of it should not depend on a mailbox.

      ⚖️ It also keeps the write inside whatever transaction or sandbox the
      caller is in, which a separate process could not join.
  """
  @spec record_cost(atom() | String.t(), non_neg_integer()) :: :ok
  def record_cost(provider, micro_cents) when is_integer(micro_cents) and micro_cents >= 0 do
    Spend.record(provider, micro_cents)

    # ⚖️ Emitted here rather than from a GenServer, which is where it used to
    # live and the only thing that process did that nothing else does.
    :telemetry.execute(
      [:stacks, :budget, :cost_recorded],
      # ⛔ `amount_micro_cents`, NOT `amount_cents`. This measurement was named
      # `amount_cents` while carrying micro-cents, and the lie travelled: a
      # PUBLIC Prometheus metric `…_amount_cents` and the platform-ops money
      # panel that divides it by 100 for dollars were both reporting 100,000×
      # the real spend, on a dashboard whose stated purpose is transparency
      # about what this costs to run.
      #
      # ⚖️ Renamed rather than converted. Converting to cents at the emit would
      # round every individual call to zero — a Together completion costs a
      # fraction of a cent, which is the entire reason the ledger meters in
      # micro-cents — so a cents-shaped metric is either wrong or blank.
      %{amount_micro_cents: micro_cents},
      %{provider: bounded_provider(provider)}
    )

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
    # ⚖️ THE LEDGER IS IN MICRO-CENTS; THE LIMITS ARE IN CENTS. The conversion
    # happens here, once, at the comparison — rather than storing the limits in
    # micro-cents, because a limit is a human decision ("five dollars a day")
    # and a spend is a measurement. Keeping the configured ceiling in the unit
    # a person would write it in is worth one multiplication.
    daily_spent = Spend.spent(provider, :daily)
    monthly_spent = Spend.spent(provider, :monthly)

    daily_limit = daily_limit * @micro_cents_per_cent
    monthly_limit = monthly_limit * @micro_cents_per_cent

    # ⛔ A GAUGE OF WHAT THE CEILING IS ACTUALLY COMPARING AGAINST.
    #
    # The existing spend series is a `sum` over `cost_recorded` events, which is
    # an accumulation of what the application happened to emit — not the
    # ledger. The two drift: a dropped event, a restart mid-charge, or a
    # retention sweep moves one and not the other, and the number a dashboard
    # shows is then not the number that refuses a request.
    #
    # ⚖️ `last_value` on the ledger's own totals, emitted at the moment the
    # decision is made, so the series answers "how close is this provider to
    # being cut off" rather than "how much have we emitted events about".
    :telemetry.execute(
      [:stacks, :budget, :spend],
      # ⚠️ Reported in CENTS, divided from the ledger's micro-cents, because the
      # panel is read by a person and the unit on the axis is currency. The
      # ledger keeps the precision; the gauge keeps the legibility.
      %{
        daily_cents: div(daily_spent, @micro_cents_per_cent),
        monthly_cents: div(monthly_spent, @micro_cents_per_cent)
      },
      %{provider: bounded_provider(provider)}
    )

    cond do
      monthly_spent >= monthly_limit ->
        :telemetry.execute(
          [:stacks, :budget, :limit_exceeded],
          %{},
          %{provider: bounded_provider(provider), type: :monthly}
        )

        {:error, :monthly_limit_exceeded}

      daily_spent >= daily_limit ->
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

  # ⛔ THE GenServer IS GONE, AND WITH IT THE SECOND COPY OF THE SPEND.
  #
  # It held `providers`, `daily_total_cents` and `monthly_total_cents` in a
  # struct, behind a `current_state/0` documented "for observability" — which
  # had **twelve references, all in test files and none in `lib/`**. Once the
  # decision moved to the durable ledger, that struct was not a cache but a
  # disagreement waiting to happen: resettable by restart, reset at midnight
  # only if the process happened to be alive, and documented in a way that
  # invited an admin panel onto the pre-fix wrong number.
  #
  # ⚠️ The unit change settled it. The ledger is micro-cents now, so the struct
  # was accumulating micro-cents into fields named `_cents` — a copy that is
  # both redundant AND mislabelled is not worth keeping for a reader that does
  # not exist.
  #
  # ⚖️ What the process actually did that nothing else does — emit
  # `[:stacks, :budget, :cost_recorded]` — moved into `record_cost/2`, where the
  # charge is. The midnight timer is unnecessary: the period is a date.

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
