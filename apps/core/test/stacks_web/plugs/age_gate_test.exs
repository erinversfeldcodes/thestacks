defmodule StacksWeb.Plugs.AgeGateTest do
  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias StacksWeb.Plugs.AgeGate

  @age_gated_book %{visibility_tier: "age_gated"}
  @public_book %{visibility_tier: "public"}

  describe "call/2 (Plug interface)" do
    test "passes conn through for a public book via keyword opts", %{conn: conn} do
      opts = AgeGate.init(book: @public_book)
      result = AgeGate.call(conn, opts)
      refute result.halted
    end

    test "halts with 403 when unauthenticated user accesses age-gated book via call/2", %{
      conn: conn
    } do
      opts = AgeGate.init(book: @age_gated_book)
      result = AgeGate.call(conn, opts)
      assert result.halted
      assert result.status == 403
    end
  end

  describe "enforce/2 for age-gated books" do
    test "halts with 403 when no user is authenticated (nil user)", %{conn: conn} do
      # conn has no Guardian resource set — current_resource returns nil
      result = AgeGate.enforce(conn, @age_gated_book)
      assert result.halted
      assert result.status == 403
    end

    test "halts with 403 when authenticated user is not age-verified", %{conn: conn} do
      user = insert(:user, age_verified: false)
      conn = Guardian.Plug.put_current_resource(conn, user)

      result = AgeGate.enforce(conn, @age_gated_book)
      assert result.halted
      assert result.status == 403
    end

    test "passes through when authenticated user is age-verified", %{conn: conn} do
      user = insert(:user, age_verified: true)
      conn = Guardian.Plug.put_current_resource(conn, user)

      result = AgeGate.enforce(conn, @age_gated_book)
      refute result.halted
    end
  end

  describe "enforce/2 for non-age-gated books" do
    test "passes conn through for public book", %{conn: conn} do
      result = AgeGate.enforce(conn, @public_book)
      refute result.halted
    end

    test "passes conn through for nil book", %{conn: conn} do
      result = AgeGate.enforce(conn, nil)
      refute result.halted
    end
  end
end
