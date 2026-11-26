defmodule Stacks.WritingAssistant.Assistant do
  @moduledoc """
      The writing assistant's response pipeline — the reader-facing seam that
      ties the wave together. One call, `respond/3`, runs a turn through every
      precondition, in order:

        1. PRECONDITIONS PRESENT — the path refuses to serve at all unless the
           four gates it depends on are loaded (`preconditions_met?/0`). Shipping
           the chat without them is the failure this guards.
        2. SAFETY PASS — a ghost-writing request is refused with a coaching
           redirect; the model is never called for it.
        3. RETRIEVAL — the prompt is embedded and the user's own corpus is
           searched, user-scoped and do-not-retrieve-filtered.
        4. GENERATION (budget-gated) — the dialogue model is asked, through
           `TogetherClient`, which refuses over budget.
        5. OUTPUT GATE — the response is checked for verbatim reproduction
           of the retrieved spans (abstain if so) and for faithfulness to them.

      Each precondition is applied here, so neutering any one of them in this
      pipeline reds the test that proves it fires — the guard can fail, which is
      what makes passing mean something.
  """

  alias Stacks.AI.{Budget, Client, TogetherClient}
  alias Stacks.WritingAssistant.{OutputGate, Retrieval, SafetyPass}

  @model "bge-m3"
  @embedding_version 1
  @default_k 8
  @abstain "I can point you at the passages that bear on this, but I won't reproduce your prose back to you — tell me what you're trying to work out and I'll help you think it through."

  @preconditions [
    {SafetyPass, :check_request, 1},
    {Retrieval, :retrieve, 3},
    {TogetherClient, :complete, 2},
    {Budget, :check_budget, 1},
    {OutputGate, :verbatim, 3},
    {OutputGate, :faithfulness, 2}
  ]

  @type result :: %{
          required(:response) => String.t(),
          required(:spans) => [String.t()],
          optional(:refused) => atom(),
          optional(:grounded) => boolean()
        }

  @doc "True only if every gate the chat path depends on is loaded."
  @spec preconditions_met?() :: boolean()
  def preconditions_met? do
    Enum.all?(@preconditions, fn {mod, fun, arity} ->
      Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
    end)
  end

  @doc """
  Produce one assistant turn. Options: `:k` (retrieved spans, default #{@default_k}).

  Returns `{:ok, result}` — where `result` may itself be a refusal (ghost-writing
  or verbatim) — or `{:error, reason}` when a precondition is missing or the model
  path fails (including `{:budget_exceeded, _}` over budget).
  """
  @spec respond(binary(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def respond(user_id, prompt, opts \\ []) when is_binary(prompt) do
    if preconditions_met?() do
      case SafetyPass.check_request(prompt) do
        {:refuse, :ghostwriting, message} ->
          {:ok, %{response: message, spans: [], refused: :ghostwriting}}

        :ok ->
          generate(user_id, prompt, opts)
      end
    else
      {:error, :preconditions_missing}
    end
  end

  defp generate(user_id, prompt, opts) do
    spans = retrieve_spans(user_id, prompt, opts)

    case TogetherClient.complete(assemble(prompt, spans)) do
      {:ok, response} -> gate(response, spans)
      {:error, reason} -> {:error, reason}
    end
  end

  defp retrieve_spans(user_id, prompt, opts) do
    case embed_query(prompt) do
      {:ok, vector} ->
        user_id
        |> Retrieval.retrieve(vector,
          embedding_version: @embedding_version,
          k: Keyword.get(opts, :k, @default_k)
        )
        |> Enum.map(& &1.chunk_text)

      :error ->
        []
    end
  end

  defp embed_query(prompt) do
    case Client.call_vision("embed", %{texts: [prompt], model: @model}) do
      {:ok, %{"vectors" => [%{"values" => vector} | _]}} -> {:ok, vector}
      _ -> :error
    end
  end

  defp assemble(prompt, spans) do
    context =
      if spans == [],
        do: "",
        else:
          "Passages from the author's own corpus — paraphrase and cite, never quote:\n\n" <>
            Enum.join(spans, "\n\n") <> "\n\n"

    OutputGate.never_verbatim_rule() <> "\n\n" <> context <> "Author: " <> prompt
  end

  defp gate(response, spans) do
    case OutputGate.verbatim(response, spans) do
      {:block, :verbatim, _run} ->
        {:ok, %{response: @abstain, spans: spans, refused: :verbatim}}

      :ok ->
        {:ok,
         %{
           response: response,
           spans: spans,
           grounded: OutputGate.faithfulness(response, spans) == :ok
         }}
    end
  end
end
