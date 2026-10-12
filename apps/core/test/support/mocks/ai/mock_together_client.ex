defmodule Stacks.AI.MockTogetherClient do
  @moduledoc """
      Mock Together AI client for tests.

      Responses are stored in the process dictionary so each test process is
      isolated and tests can run with `async: true`.

      ## Usage

          MockTogetherClient.put_response({:ok, "A great book summary."})

      Unmatched calls return a default summary.

      Every call is also recorded, in order, with the text it was handed —
      `sent/0`. A consent gate is only proved by what did NOT cross the seam,
      and an unrecorded mock cannot tell "the gate held" apart from "the mock
      was never reachable in the first place".
  """

  @behaviour Stacks.AI.TogetherClientBehaviour

  @sent_key {__MODULE__, :sent}

  @impl true
  def summarize_reviews(review_text, book_context) do
    record({:summarize_reviews, review_text, book_context})

    get_response(
      {:ok,
       "Readers generally enjoyed this book, praising its engaging narrative and well-developed characters."}
    )
  end

  @impl true
  def complete(prompt, opts \\ []) do
    record({:complete, prompt, opts})
    get_response({:ok, "0.75"})
  end

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
      `{:complete, prompt, opts}` / `{:summarize_reviews, text, context}`.
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
    Process.delete(__MODULE__)
  end
end
