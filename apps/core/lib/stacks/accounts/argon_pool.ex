defmodule Stacks.Accounts.ArgonPool do
  @moduledoc false
  @behaviour NimblePool

  # Pools Argon2 operations so concurrent login/password-change requests cannot
  # collectively exhaust available memory. Each Argon2 call uses ~64 MB; with
  # pool_size: 2 at most 128 MB is committed at once, keeping peak RSS safe on
  # constrained machines (Fly preview: 256 MB, staging: 512 MB).
  #
  # When all workers are occupied, run/1 returns {:error, :argon2_busy} after
  # 10 seconds. Callers map this to 503 + Retry-After: 5.
  #
  # Pool size is tunable via config :core, :argon2_pool_size (default: 2).

  @pool_size Application.compile_env(:core, :argon2_pool_size, 2)

  def child_spec(_opts) do
    NimblePool.child_spec(worker: {__MODULE__, []}, pool_size: @pool_size, name: __MODULE__)
  end

  @doc """
  Runs `fun` inside a pool checkout, bounding concurrent Argon2 operations.
  Returns the result of `fun.()`, or `{:error, :argon2_busy}` if all pool workers
  are occupied and the checkout times out after 10 seconds.
  """
  @spec run(fun :: (-> term())) :: term() | {:error, :argon2_busy}
  def run(fun) do
    NimblePool.checkout!(
      __MODULE__,
      :checkout,
      fn _from, nil ->
        result = fun.()
        {result, nil}
      end,
      10_000
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
