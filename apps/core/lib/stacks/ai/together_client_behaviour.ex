defmodule Stacks.AI.TogetherClientBehaviour do
  @moduledoc "Behaviour for the Together AI LLM client — allows test mocking via Application env."

  @callback summarize_reviews(review_text :: String.t(), book_context :: map()) ::
              {:ok, String.t()} | {:error, term()}

  @callback complete(prompt :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
