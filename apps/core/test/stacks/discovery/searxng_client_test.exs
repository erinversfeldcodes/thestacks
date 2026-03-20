defmodule Stacks.Discovery.SearxngClientTest do
  use ExUnit.Case, async: true

  alias Stacks.Discovery.MockSearxngClient

  describe "MockSearxngClient" do
    test "returns empty list by default" do
      assert {:ok, []} = MockSearxngClient.search("test query")
    end

    test "returns configured response" do
      results = [
        %{title: "Book Event", url: "https://example.com", description: "A great event"}
      ]

      MockSearxngClient.put_response({:ok, results})
      assert {:ok, ^results} = MockSearxngClient.search("test query")
    end

    test "returns error response when configured" do
      MockSearxngClient.put_response({:error, :connection_refused})
      assert {:error, :connection_refused} = MockSearxngClient.search("test query")
    end

    test "clear/0 resets to default" do
      MockSearxngClient.put_response({:ok, [%{title: "test", url: "", description: ""}]})
      MockSearxngClient.clear()
      assert {:ok, []} = MockSearxngClient.search("test query")
    end
  end
end
