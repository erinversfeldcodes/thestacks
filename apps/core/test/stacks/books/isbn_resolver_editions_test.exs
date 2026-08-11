defmodule Stacks.Books.ISBNResolverEditionsTest do
  @moduledoc """
  Tests `ISBNResolver.editions_for_work/1` — discovering a work's other editions.

  A work is the abstract book; an edition is a printing with its own ISBN. Shops stock
  whichever edition they stock, so this is what lets a price lookup find the copy a
  reader can actually buy (Exclusive Books carries six ISBNs of *The Name of the Rose*).

  The behaviour worth guarding is not "it parses JSON" — it is the **bounds**. Open
  Library paginates `editions.json` and a popular work has a long tail: the work
  measured during planning had 151 editions carrying 76 distinct ISBN-13s, and each
  discovered ISBN is a future price-lookup target across every configured store.
  """

  use ExUnit.Case, async: true

  alias Stacks.Books.ISBNResolver
  alias Stacks.Books.MockHttpClient

  @editions_url "openlibrary.org/works"

  setup do
    original = Application.get_env(:core, :isbn_http_client)
    Application.put_env(:core, :isbn_http_client, MockHttpClient)

    on_exit(fn ->
      if original,
        do: Application.put_env(:core, :isbn_http_client, original),
        else: Application.delete_env(:core, :isbn_http_client)
    end)

    :ok
  end

  defp entries(isbn_lists) do
    %{"entries" => Enum.map(isbn_lists, &%{"isbn_13" => &1})}
  end

  describe "editions_for_work/1" do
    test "returns the ISBN-13s of a work's editions" do
      MockHttpClient.put_response(
        @editions_url,
        {:ok, entries([["9780156001311"], ["9788497592581"]])}
      )

      assert {:ok, isbns} = ISBNResolver.editions_for_work("OL27448W")
      assert isbns == ["9780156001311", "9788497592581"]
    end

    test "deduplicates ISBNs that appear on more than one edition record" do
      MockHttpClient.put_response(
        @editions_url,
        {:ok, entries([["9780156001311"], ["9780156001311"], ["9788497592581"]])}
      )

      assert {:ok, isbns} = ISBNResolver.editions_for_work("OL27448W")
      assert isbns == ["9780156001311", "9788497592581"]
    end

    test "drops ISBN-10s rather than returning a mixture" do
      MockHttpClient.put_response(
        @editions_url,
        {:ok,
         %{
           "entries" => [
             %{"isbn_13" => ["9780156001311"], "isbn_10" => ["0156001311"]},
             %{"isbn_10" => ["0330491199"]}
           ]
         }}
      )

      assert {:ok, ["9780156001311"]} = ISBNResolver.editions_for_work("OL27448W")
    end

    test "caps the result, because a work's edition list is a long tail" do
      many = for i <- 1..60, do: ["978015600#{String.pad_leading("#{i}", 4, "0")}"]
      MockHttpClient.put_response(@editions_url, {:ok, entries(many)})

      assert {:ok, isbns} = ISBNResolver.editions_for_work("OL27448W")

      assert length(isbns) == 50,
             "expected the cap to bound the result, got #{length(isbns)}"
    end

    test "asks for one page and does not paginate" do
      MockHttpClient.capture_requests()
      MockHttpClient.put_response(@editions_url, {:ok, entries([["9780156001311"]])})

      assert {:ok, _} = ISBNResolver.editions_for_work("OL27448W")

      assert_received {MockHttpClient, :request, url}

      assert url =~ "limit=50", "the cap must be pushed to the server, not applied after"
      refute url =~ "offset", "an offset means we started walking pages"

      refute_received {MockHttpClient, :request, _},
                      "a second request means pagination — which makes the fan-out unbounded"
    end

    test "a work with no editions is an empty list, not an error" do
      MockHttpClient.put_response(@editions_url, {:ok, %{"entries" => []}})
      assert {:ok, []} = ISBNResolver.editions_for_work("OL27448W")
    end

    test "a sparse or unexpected payload yields no editions rather than crashing" do
      for body <- [%{}, %{"entries" => nil}, %{"entries" => [%{"isbn_13" => nil}, "junk"]}] do
        MockHttpClient.clear()
        MockHttpClient.put_response(@editions_url, {:ok, body})

        assert {:ok, []} = ISBNResolver.editions_for_work("OL27448W"),
               "unexpected payload should be empty, not a crash: #{inspect(body)}"
      end
    end

    test "a blank or non-binary work id is refused without a request" do
      MockHttpClient.capture_requests()

      assert {:error, :not_found} = ISBNResolver.editions_for_work("")
      assert {:error, :not_found} = ISBNResolver.editions_for_work(nil)

      refute_received {MockHttpClient, :request, _},
                      "a bad work id must not reach the network"
    end
  end
end
