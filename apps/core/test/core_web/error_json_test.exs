defmodule CoreWeb.ErrorJSONTest do
  use CoreWeb.ConnCase, async: true

  describe "render/2" do
    test "returns error detail for a 404 template" do
      result = CoreWeb.ErrorJSON.render("404.json", %{})
      assert %{errors: %{detail: "Not Found"}} = result
    end

    test "returns error detail for a 500 template" do
      result = CoreWeb.ErrorJSON.render("500.json", %{})
      assert %{errors: %{detail: "Internal Server Error"}} = result
    end
  end
end
