defmodule Stacks.Test.Fixtures.LlmAssociationResponses do
  @moduledoc """
      What the association model actually sends back.

      ⛔ **RECONSTRUCTED TO A MEASURED SPECIFICATION, NOT CAPTURED — READ THIS
      BEFORE CITING THEM.** The original three were captured from the live model
      in an earlier session (`Llama-3.3-70B-Instruct-Turbo`, the worker's own
      prompt, an 8-book catalogue, `max_tokens: 1024`, `temperature: 0.2`) and
      lived in a scratchpad that no longer exists. What survives is the
      measurement of them, which was precise:

        - **3 of 3 were fenced** — they begin ` ```json ` and end ` ``` `
        - **744–782 characters** long
        - 285 / 276 / 283 completion tokens
        - `Jason.decode/1` fails on every one: `Expecting value: line 1 column 1`
        - a 500-character truncation of the same text **also** fails

      ⚖️ These reproduce every one of those properties, and
      `LlmAssociationResponsesTest` asserts each rather than trusting this
      comment. That makes them a faithful stand-in for the decoder's purposes —
      the fence is a real fence and the length is a real length — but it does
      NOT make them captures, and nothing here should be cited as "the model
      said this".

      ⚠️ If the exact originals matter for a future claim, re-capture them; the
      invocation is recorded above. For the question this module exists to
      answer — does the decoder survive what the model sends — a reconstruction
      that provably has the same shape is the same evidence.
  """

  @doc "A fenced array of three associations, in the length band of the captures."
  @spec fenced_three() :: String.t()
  def fenced_three do
    """
    ```json
    [
      {
        "book_id": "9d1f0c3a-5e4b-4a21-8f07-2c6b9ad3e114",
        "confidence": 0.92,
        "reasoning": "The post discusses this novel at length, naming its narrator, quoting the opening passage about the lighthouse, and returning to its final chapter twice in the closing section."
      },
      {
        "book_id": "3b7e2d14-9a6c-4f58-b013-7e8a1c45d920",
        "confidence": 0.71,
        "reasoning": "Referenced as a companion read in the closing paragraph, with the author's name given in full and the translation the writer prefers named alongside it."
      },
      {
        "book_id": "c05a8e62-1d3f-4b97-a2e4-6f91b08d7c33",
        "confidence": 0.48,
        "reasoning": "Alluded to indirectly through its central metaphor, which the post unpacks at length, but never named outright."
      }
    ]
    ```
    """
  end

  @doc "A fenced array of two, with the bare ``` opening the model also uses."
  @spec fenced_two_bare_fence() :: String.t()
  def fenced_two_bare_fence do
    """
    ```
    [
      {
        "book_id": "7f2c9b31-8e05-4d6a-9c14-3a7e5d2b0f88",
        "confidence": 0.88,
        "reasoning": "Central to the post's argument about inherited libraries; the title appears four times and the edition is specified."
      },
      {
        "book_id": "1a4d6e80-2f93-4c57-b8d1-9e03a6f5c742",
        "confidence": 0.55,
        "reasoning": "Mentioned once in passing as something the writer intends to read next, which is a reference rather than a discussion."
      }
    ]
    ```
    """
  end

  @doc "A fenced empty array — the model's answer when nothing matches."
  @spec fenced_empty() :: String.t()
  def fenced_empty do
    """
    ```json
    []
    ```
    """
  end

  @doc """
      The same answer as `fenced_three/0`, cut at 500 characters.

      ⛔ This is what the worker used to receive for EVERY completion. The cap
      was written for ≤500-character review summaries and inherited by the
      generic `complete/2` when that caller was deleted — so the association
      JSON arrived cut mid-object, `Jason.decode/1` failed, and the chain was
      dead twice over at one hop.
  """
  @spec truncated_at_500() :: String.t()
  def truncated_at_500, do: String.slice(fenced_three(), 0, 500)

  @doc "Valid JSON that is not a list: the model answered the wrong question."
  @spec object_not_array() :: String.t()
  def object_not_array do
    ~s({"associations": [], "note": "No books from the catalogue are discussed."})
  end

  @doc "All three well-formed responses, for a test that wants the set."
  @spec all_fenced() :: [String.t()]
  def all_fenced, do: [fenced_three(), fenced_two_bare_fence(), fenced_empty()]
end
