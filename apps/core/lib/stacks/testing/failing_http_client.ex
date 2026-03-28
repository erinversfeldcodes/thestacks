defmodule Stacks.Testing.FailingHttpClient do
  @moduledoc """
  ISBN resolver HTTP client stub that always returns a connection error.

  Used by the circuit breaker smoke endpoint to blow ISBN fuses without making
  real HTTP calls. Compiled in all environments; the smoke endpoint itself is
  gated by `config :core, :smoke_tests_enabled` (false in production).
  """

  @behaviour Stacks.Books.HttpClientBehaviour

  @impl true
  def get(_url), do: {:error, :econnrefused}
end
