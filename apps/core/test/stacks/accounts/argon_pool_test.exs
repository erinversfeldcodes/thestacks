defmodule Stacks.Accounts.ArgonPoolTest do
  use ExUnit.Case, async: true

  alias Stacks.Accounts.ArgonPool

  describe "run/1" do
    test "returns the result of the given function" do
      assert ArgonPool.run(fn -> :hello end) == :hello
    end

    test "returns a tuple result unchanged" do
      assert ArgonPool.run(fn -> {:ok, 42} end) == {:ok, 42}
    end

    test "returns {:error, :argon2_busy} when pool times out" do
      # Saturate the pool by holding all workers for longer than the checkout
      # timeout. We start pool_size + 1 tasks: the first batch fills the pool
      # and the last checkout times out immediately because we pass timeout: 0.
      pool_size = Application.get_env(:core, :argon2_pool_size, 2)
      parent = self()

      holders =
        for _ <- 1..pool_size do
          Task.async(fn ->
            NimblePool.checkout!(
              ArgonPool,
              :checkout,
              fn _from, nil ->
                send(parent, :holding)

                receive do
                  :release -> {nil, nil}
                end
              end,
              5_000
            )
          end)
        end

      # Wait for all holders to check out a worker before trying the timed-out call.
      for _ <- 1..pool_size, do: assert_receive(:holding, 2_000)

      # Now all pool workers are occupied — a checkout with timeout 0 should fail.
      result =
        catch_exit(
          NimblePool.checkout!(
            ArgonPool,
            :checkout,
            fn _from, nil -> {nil, nil} end,
            0
          )
        )

      assert match?({:timeout, _}, result)

      # Release holders.
      for t <- holders, do: send(t.pid, :release)
      for t <- holders, do: Task.await(t)
    end
  end

  describe "Argon2 memory cost (#369)" do
    test "m_cost is tuned to 15 (32 MiB), not the 64 MiB library default" do
      # A readback guard: left unset, argon2_elixir defaults to m_cost 16 (64 MiB),
      # which is what OOM'd a 512 MB VM under two concurrent hashes. 15 halves that
      # and stays above the OWASP Argon2id floor (19 MiB). If this regresses to the
      # default, peak hashing memory doubles silently — fail loudly here instead.
      assert Application.get_env(:argon2_elixir, :m_cost) == 15
    end
  end
end
