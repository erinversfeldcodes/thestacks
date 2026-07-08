defmodule StacksWeb.Plugs.E2ETestHelper do
  @moduledoc """
  Gate for test-only helper endpoints (Issue #124).

  These endpoints expose data that must NEVER be reachable in production —
  e.g. a user's raw `email_confirmation_token`, which is an account-activation
  secret. The only thing standing between that secret and the public internet
  is this plug, so it fails closed.

  ## Guard

  The endpoint is handled **only** when the server environment variable
  `STACKS_E2E_TEST_HELPERS` is exactly `"1"`. For any other value (including
  absent, empty, or `"true"`) the plug responds `404 Not Found` and halts the
  pipeline before the controller runs.

  Production never sets `STACKS_E2E_TEST_HELPERS=1`, so every request to a
  gated route returns 404 there. The flag is read live via `System.get_env/1`
  on each request (not memoised at boot), which keeps the guard honest and
  makes it directly togglable in tests.
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
