defmodule StacksWeb.Plugs.ConsentCheckTest do
  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.GDPR.Consent
  alias StacksWeb.Plugs.ConsentCheck

  defp with_current_user(conn, user) do
    Guardian.Plug.put_current_resource(conn, user)
  end

  describe "call/2" do
    test "passes conn through when user has granted consent", %{conn: conn} do
      user = insert(:user)
      {:ok, _} = Consent.grant_consent(user.id)
      conn = with_current_user(conn, user)

      result = ConsentCheck.call(conn, feature: "analytics")
      refute result.halted
    end

    test "halts with 403 when user has not granted consent", %{conn: conn} do
      user = insert(:user)
      conn = with_current_user(conn, user)

      result = ConsentCheck.call(conn, feature: "analytics")
      assert result.halted
      assert result.status == 403
    end

    test "halts with 403 when no user is authenticated", %{conn: conn} do
      result = ConsentCheck.call(conn, feature: "analytics")
      assert result.halted
      assert result.status == 403
    end

    test "response body includes the feature name", %{conn: conn} do
      user = insert(:user)
      conn = with_current_user(conn, user)

      result = ConsentCheck.call(conn, feature: "analytics")
      body = Jason.decode!(result.resp_body)
      assert body["feature"] == "analytics"
      assert body["error"] == "consent_required"
    end

    test "defaults to analytics feature when none specified", %{conn: conn} do
      user = insert(:user)
      conn = with_current_user(conn, user)

      result = ConsentCheck.call(conn, [])
      assert result.halted
    end

    test "passes through when writing_assistant consent is granted", %{conn: conn} do
      user = insert(:user)
      {:ok, _} = Consent.grant_consent(user.id, "writing_assistant")
      conn = with_current_user(conn, user)

      result = ConsentCheck.call(conn, feature: "writing_assistant")
      refute result.halted
    end

    test "halts with 403 when writing_assistant consent is not granted", %{conn: conn} do
      user = insert(:user)
      {:ok, _} = Consent.grant_consent(user.id, "analytics")
      conn = with_current_user(conn, user)

      result = ConsentCheck.call(conn, feature: "writing_assistant")
      assert result.halted
      assert result.status == 403
    end
  end
end
