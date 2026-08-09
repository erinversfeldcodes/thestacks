defmodule Stacks.Testing.FailingHttpClient do
  @moduledoc """
  ISBN resolver HTTP client stub that always returns a transport error.

  Used by the circuit breaker smoke endpoint to blow ISBN fuses without making
  real HTTP calls. Compiled in all environments; the smoke endpoint itself is
  gated by `config :core, :smoke_tests_enabled` (false in production).

  Returns `{:error, :transport_error}` — the closed-set equivalent of an
  unreachable upstream (DNS down, connection refused, etc.). See
  `Stacks.Books.HttpClientBehaviour` for the full closed atom set.
  """

  @behaviour Stacks.Books.HttpClientBehaviour

  @impl true
  def get(_url), do: {:error, :transport_error}

  @impl true
  def get_binary(_url), do: {:error, :transport_error}
end
