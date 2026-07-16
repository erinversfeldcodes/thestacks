defmodule Stacks.AI.MockClientTest do
  use ExUnit.Case, async: true

  alias Stacks.AI.MockClient

  describe "call_vision/2" do
    test "is_book returns book classification" do
      assert {:ok, result} = MockClient.call_vision("is_book", %{})
      assert result["classification"] == "CLASSIFICATION_RESULT_BOOK"
    end

    test "extract_isbn with default isbn" do
      assert {:ok, result} = MockClient.call_vision("extract_isbn", %{})
      [book] = result["books"]
      assert "9780743273565" in book["potential_isbns"]
    end

    test "extract_isbn uses provided isbn from payload" do
      assert {:ok, result} = MockClient.call_vision("extract_isbn", %{isbn: "9780306406157"})
      [book] = result["books"]
      assert "9780306406157" in book["potential_isbns"]
    end

    test "unknown endpoint returns empty map" do
      assert {:ok, result} = MockClient.call_vision("unknown_endpoint", %{})
      assert result == %{}
    end
  end
end
