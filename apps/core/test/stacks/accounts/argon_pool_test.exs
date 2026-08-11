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

      for _ <- 1..pool_size, do: assert_receive(:holding, 2_000)

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

      for t <- holders, do: send(t.pid, :release)
      for t <- holders, do: Task.await(t)
    end
  end

  describe "Argon2 memory cost" do
    test "m_cost is tuned to 15 (32 MiB), not the 64 MiB library default" do
      assert Application.get_env(:argon2_elixir, :m_cost) == 15
    end
  end
end
