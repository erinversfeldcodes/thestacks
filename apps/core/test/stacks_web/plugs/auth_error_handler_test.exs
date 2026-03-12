defmodule StacksWeb.Plugs.AuthErrorHandlerTest do
  use CoreWeb.ConnCase, async: true

  alias StacksWeb.Plugs.AuthErrorHandler

  describe "auth_error/3" do
    test "returns 401 for :unauthenticated error", %{conn: conn} do
      result = AuthErrorHandler.auth_error(conn, {:unauthenticated, :token_expired}, [])
      assert result.halted
      assert result.status == 401
    end

    test "returns 403 for :unauthorized error", %{conn: conn} do
      result = AuthErrorHandler.auth_error(conn, {:unauthorized, :invalid_resource}, [])
      assert result.halted
      assert result.status == 403
    end

    test "returns 401 for any other error type", %{conn: conn} do
      result = AuthErrorHandler.auth_error(conn, {:some_other_error, :reason}, [])
      assert result.halted
      assert result.status == 401
    end
  end
end
