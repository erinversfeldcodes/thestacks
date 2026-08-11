defmodule StacksWeb.Plugs.E2ETestHelper do
  @moduledoc """
    Gate for test-only helper endpoints — the ONLY thing between secrets
    like a raw `email_confirmation_token` and the public internet, so it
    fails closed: the route is handled only when `STACKS_E2E_TEST_HELPERS`
    is exactly `"1"`; any other value (absent, empty, `"true"`) → 404 and
    halt. Read live via `System.get_env/1` per request, not memoised at
    boot, so tests can toggle it directly.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @flag "STACKS_E2E_TEST_HELPERS"

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    if enabled?() do
      conn
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "not_found"})
      |> halt()
    end
  end

  @doc """
    Whether the test-helper endpoints are enabled for this server process.

    True only when `STACKS_E2E_TEST_HELPERS` is exactly `"1"`.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: System.get_env(@flag) == "1"
end
