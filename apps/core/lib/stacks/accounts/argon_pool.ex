defmodule Stacks.Accounts.ArgonPool do
  @moduledoc false
  @behaviour NimblePool

  @pool_size Application.compile_env(:core, :argon2_pool_size, 2)

  def child_spec(_opts) do
    NimblePool.child_spec(worker: {__MODULE__, []}, pool_size: @pool_size, name: __MODULE__)
  end

  @default_checkout_timeout_ms 10_000

  @doc """
  Runs `fun` inside a pool checkout, bounding concurrent Argon2 operations.
  Returns the result of `fun.()`, or `{:error, :argon2_busy}` if all pool workers
  are occupied and the checkout times out (default 10 seconds, configurable via
  `config :core, :argon2_checkout_timeout_ms`).
  """
  @spec run(fun :: (-> term())) :: term() | {:error, :argon2_busy}
  def run(fun) do
    timeout =
      Application.get_env(:core, :argon2_checkout_timeout_ms, @default_checkout_timeout_ms)

    NimblePool.checkout!(
      __MODULE__,
      :checkout,
      fn _from, nil ->
        result = fun.()
        {result, nil}
      end,
      timeout
    )
  catch
    :exit, {:timeout, _} -> {:error, :argon2_busy}
  end

  @impl NimblePool
  def init_worker(pool_state), do: {:ok, nil, pool_state}

  @impl NimblePool
  def handle_checkout(:checkout, _from, nil, pool_state), do: {:ok, nil, nil, pool_state}

  @impl NimblePool
  def handle_checkin(nil, _from, nil, pool_state), do: {:ok, nil, pool_state}
end
