defmodule Stacks.WritingAssistant.SafetyPass do
  @moduledoc """
      The input safety pass for the writing assistant, enforcing the one rule the
      assistant exists to keep: it COACHES, it does not GHOST-WRITE.

      A request to produce the author's creative prose *for* them — write the next
      chapter, continue the story, finish the poem, draft it in my voice — is
      refused; the assistant questions and critiques instead. Requests to think
      *with* the author (feedback, critique, what-works, consistency, summarise)
      pass through untouched.

      This is the rule-based front of the safety pass, and the part that carries a
      recorded red-team (`safety_pass_test.exs` is that record). A broader,
      latency-tolerant Llama-Guard-class classifier runs alongside for general
      safety; it is the start, not the record, and does not replace this refusal.
  """

  # A ghost-writing request names a creative unit and a verb that PRODUCES it.
  # "Summarise my chapter" or "what do you think of this scene" carry no
  # producing verb over a creative unit, so they pass — coaching, not writing.
  @creative_unit "chapter|paragraph|scene|stanza|verse|line|lines|section|page|passage|story|poem|ending|opening|dialogue|monologue|novel|draft|manuscript"

  defp ghostwriting_patterns do
    [
      ~r/\b(?:write|compose|pen|draft|author)\b[^.?!]*\b(?:#{@creative_unit})\b/i,
      ~r/\b(?:continue|finish|complete|keep writing)\b[^.?!]*\b(?:my|the|this)\b[^.?!]*\b(?:#{@creative_unit})\b/i,
      ~r/\bwrite\b[^.?!]*\bfor me\b/i,
      ~r/\bghost[\s-]?writ/i,
      ~r/\bin my (?:voice|style)\b[^.?!]*\b(?:write|draft|compose)\b/i,
      ~r/\b(?:write|draft|compose)\b[^.?!]*\bin my (?:voice|style)\b/i
    ]
  end

  @refusal "I won't write it for you — that is your work and your voice. I can help you think it through instead: what are you trying to do in this passage, and where does it feel stuck?"

  @doc "The refusal the assistant returns for a ghost-writing request."
  @spec refusal() :: String.t()
  def refusal, do: @refusal

  @doc "True if the prompt asks the assistant to produce the author's creative prose."
  @spec ghostwriting_request?(String.t()) :: boolean()
  def ghostwriting_request?(prompt) when is_binary(prompt),
    do: Enum.any?(ghostwriting_patterns(), &Regex.match?(&1, prompt))

  @doc """
      Check an incoming request. A ghost-writing attempt is refused with the
      coaching redirect; everything else passes.
  """
  @spec check_request(String.t()) :: :ok | {:refuse, :ghostwriting, String.t()}
  def check_request(prompt) do
    if ghostwriting_request?(prompt), do: {:refuse, :ghostwriting, @refusal}, else: :ok
  end
end
