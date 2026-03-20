defmodule Stacks.Discovery.BraveClientTest do
  use Core.DataCase, async: true

  alias Stacks.Discovery.MockBraveClient

  describe "MockBraveClient.search/2" do
    test "returns empty list when no response is registered" do
      assert {:ok, []} = MockBraveClient.search("test query")
    end

    test "returns registered response" do
      results = [
        %{title: "Author Blog", url: "https://author.com", description: "An author's blog"}
      ]

      MockBraveClient.put_response({:ok, results})
      assert {:ok, ^results} = MockBraveClient.search("test query")
    end

    test "returns error when error response is registered" do
      MockBraveClient.put_response({:error, :rate_limited})
      assert {:error, :rate_limited} = MockBraveClient.search("test query")
    end

    test "clear removes registered response" do
      MockBraveClient.put_response(
        {:ok, [%{title: "Test", url: "https://test.com", description: ""}]}
      )

      MockBraveClient.clear()
      assert {:ok, []} = MockBraveClient.search("test query")
    end
  end
end
