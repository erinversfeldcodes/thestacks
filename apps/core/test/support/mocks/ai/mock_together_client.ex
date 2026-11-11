defmodule Stacks.AI.MockTogetherClient do
  @moduledoc """
      Mock Together AI client for tests.

      Responses are stored in the process dictionary so each test process is
      isolated and tests can run with `async: true`.

      ## Usage

          MockTogetherClient.put_response({:ok, "0.9"})

      Unmatched calls return a default completion.

      Every call is also recorded, in order, with the text it was handed —
      `sent/0`. A consent gate is only proved by what did NOT cross the seam,
      and an unrecorded mock cannot tell "the gate held" apart from "the mock
      was never reachable in the first place".
  """

  @behaviour Stacks.AI.TogetherClientBehaviour

  alias Stacks.AI.Budget
  alias Stacks.AI.TogetherClient

  @sent_key {__MODULE__, :sent}
  @usage_key {__MODULE__, :usage_tokens}

  @impl true
  def complete(prompt, opts \\ []) do
    record({:complete, prompt, opts})

    # ⛔ THE CHECK, NOT ONLY THE CHARGE. This mock reproduced
    # `do_complete/2`'s charge and silently dropped its budget check, so the
    # only ceiling on the system's most expensive LLM path had no test that
    # could fail. Measured before this line existed: with 200,000 micro-cents
    # spent against a 100,000 ceiling the worker returned `:ok` and billed
    # 35,200 more.
    #
    # ⚠️ The asymmetry is what made it invisible. A reader auditing coverage
    # sees a mock, assumes the seam is the transport — which is what the
    # moduledoc says — and never asks what else the real function did. A mock
    # replacing a function wholesale replaces every guard inside it.
    #
    # ⚖️ Same call, same order as `do_complete/2`, so the refusal shape the
    # worker matches on is the shape it gets in production.
    case Budget.check_budget(:together) do
      :ok ->
        case get_response({:ok, "0.75"}) do
          {:ok, content} -> charge_like_the_real_client(content)
          other -> other
        end

      # ⛔ WRAPPED EXACTLY AS `do_complete/2` WRAPS IT. A bare `with` passes
      # `{:error, :daily_limit_exceeded}` straight through, and the worker
      # matches `{:error, {:budget_exceeded, limit}}` — so the mock would
      # refuse the call and the worker would not recognise the refusal, which
      # is a *different* untested path rather than the one being covered.
      #
      # ⚠️ Caught by the test going green-then-red on its own terms: the
      # ceiling refused, and the job still returned `:ok`. Faking a guard means
      # faking its failure SHAPE, not only its decision.
      {:error, limit} when limit in [:daily_limit_exceeded, :monthly_limit_exceeded] ->
        {:error, {:budget_exceeded, limit}}
    end
  end

  # ⛔ THE MOCK CHARGES THE BUDGET, BECAUSE OTHERWISE NOTHING IN THE TEST
  # ENVIRONMENT EVER DOES.
  #
  # `config :core, :together_client, #{inspect(__MODULE__)}` replaces
  # `complete/2` wholesale, so a mock that answers with a bare string bypasses
  # the real client's success path — and the charge lives there, where the
  # provider's token usage is. The effect is that every worker driven under the
  # mock spends nothing, and a test asking "was this billed?" cannot tell a
  # working meter from an absent one.
  #
  # ⚖️ So the mock stops short of reimplementing the billing and instead hands a
  # canned envelope to the REAL parser. Only the transport is faked; the
  # charging, the usage reading and the rounding are the shipped code. A mock
  # that computed the cost itself would be a second implementation of the thing
  # under test, and the two would drift.
  defp charge_like_the_real_client(content) do
    body =
      Jason.encode!(%{
        "choices" => [%{"message" => %{"content" => content}}],
        "usage" => %{"total_tokens" => usage_tokens()}
      })

    TogetherClient.parse_success_response(body)
  end

  @doc """
      The `usage.total_tokens` the next canned response will report.

      Defaults to a small, realistic completion. Set it when a test needs the
      charge to be a particular size.
  """
  @spec put_usage_tokens(non_neg_integer()) :: term()
  def put_usage_tokens(tokens), do: Process.put(@usage_key, tokens)

  defp usage_tokens, do: Process.get(@usage_key, 400)

  defp get_response(default) do
    case Process.get(__MODULE__) do
      nil -> default
      response -> response
    end
  end

  defp record(call) do
    Process.put(@sent_key, Process.get(@sent_key, []) ++ [call])
  end

  @doc """
      Everything handed to the client in this test process, oldest first, as
      `{:complete, prompt, opts}`.
  """
  @spec sent() :: [tuple()]
  def sent, do: Process.get(@sent_key, [])

  @doc "Register a response for the current test process."
  @spec put_response({:ok, String.t()} | {:error, term()}) :: term()
  def put_response(response) do
    Process.put(__MODULE__, response)
  end

  @doc "Clear registered responses and the record of calls for the current process."
  @spec clear() :: term()
  def clear do
    Process.delete(@sent_key)
    Process.delete(@usage_key)
    Process.delete(__MODULE__)
  end
end
