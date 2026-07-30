defmodule Stacks.AI.MockTogetherClient do
  @moduledoc """
  Mock Together AI client for tests.

  Responses are stored in the process dictionary so each test process is
  isolated and tests can run with `async: true`.

  ## Usage

      MockTogetherClient.put_response({:ok, "A great book summary."})

  Unmatched calls return a default summary.
  """

  @behaviour Stacks.AI.TogetherClientBehaviour

  @impl true
  def summarize_reviews(_review_text, _book_context) do
    get_response(
      {:ok,
       "Readers generally enjoyed this book, praising its engaging narrative and well-developed characters."}
    )
  end

  @impl true
  def complete(_prompt, _opts \\ []) do
    get_response({:ok, "0.75"})
  end

  defp get_response(default) do
    case Process.get(__MODULE__) do
      nil -> default
      response -> response
    end
  end

  @doc "Register a response for the current test process."
  @spec put_response({:ok, String.t()} | {:error, term()}) :: term()
  def put_response(response) do
    Process.put(__MODULE__, response)
  end

  @doc "Clear registered responses for the current process."
  @spec clear() :: term()
  def clear do
    Process.delete(__MODULE__)
  end
end
