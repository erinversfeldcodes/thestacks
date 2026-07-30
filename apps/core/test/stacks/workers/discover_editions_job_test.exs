defmodule Stacks.Workers.DiscoverEditionsJobTest do
  @moduledoc """
  Tests `DiscoverEditionsJob` — turning a work's Open Library edition list into rows.

  What matters here is the **bounds and the gate**, not that a row can be inserted:
  each merge re-resolves its ISBN to honour the ISBN hard gate, so an uncapped run is
  an unbounded number of resolver races per new book. The fetch cap (50) lives in
  `ISBNResolver`; the creation cap (10) lives here, sized against what
  `Prices.enqueue_refreshes/1` will actually price.
  """

  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Books.BookEdition
  alias Stacks.Books.MockHttpClient
  alias Stacks.Workers.DiscoverEditionsJob

  @primary "9780156001311"

  # Generates a *valid* ISBN-13 for index `i`, check digit included.
  #
  # ⚠️ Necessary, not decorative. The first draft of the cap test used hand-typed
  # sequential ISBNs whose check digits were wrong, so every one was refused before the
  # cap was ever consulted — `created <= 10` held because `created` was 0. The test
  # passed with the cap **deleted**, which is the definition of vacuous. A mutation probe
  # is what surfaced it.
  defp isbn13(i) do
    base = "97801562" <> String.pad_leading("#{i}", 4, "0")

    check =
      base
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, idx}, acc ->
        acc + String.to_integer(d) * if(rem(idx, 2) == 0, do: 1, else: 3)
      end)
      |> then(&rem(10 - rem(&1, 10), 10))

    base <> "#{check}"
  end

  setup do
    original = Application.get_env(:core, :isbn_http_client)
    Application.put_env(:core, :isbn_http_client, MockHttpClient)

    on_exit(fn ->
      MockHttpClient.clear()

      if original,
        do: Application.put_env(:core, :isbn_http_client, original),
        else: Application.delete_env(:core, :isbn_http_client)
    end)

    book =
      insert(:book,
        title: "The Name of the Rose",
        editions: [build(:primary_book_edition, isbn: @primary)]
      )

    %{book: book}
  end

  # Open Library's ISBN lookup shape, with the work key the job needs.
  defp stub_resolve(work_id) do
    MockHttpClient.put_response(
      "openlibrary.org/api/books",
      {:ok,
       %{
         "ISBN:#{@primary}" => %{
           "title" => "The Name of the Rose",
           "authors" => [%{"name" => "Umberto Eco"}],
           "works" => [%{"key" => "/works/#{work_id}"}]
         }
       }}
    )
  end

  # Registers the work's edition list AND makes each listed ISBN independently
  # resolvable. Both halves are needed: `Books.merge_edition/2` re-resolves every ISBN to
  # honour the ISBN hard gate, so an ISBN that Open Library merely *lists* is correctly
  # refused. Stubbing only the list produced a test where nothing was ever created —
  # which is the gate working, not a bug, and is asserted directly further down.
  defp stub_editions(isbns) do
    MockHttpClient.put_response(
      "openlibrary.org/works",
      {:ok, %{"entries" => Enum.map(isbns, &%{"isbn_13" => [&1]})}}
    )

    # Deliberately skips @primary: its resolve stub is the one carrying the `works` key
    # that the job needs to find the work at all, and MockHttpClient lets later
    # registrations win — so stubbing the primary here would silently replace the work
    # key with a response that has none, and the job would exit before doing anything.
    isbns
    |> Enum.reject(&(&1 == @primary))
    |> Enum.each(fn isbn ->
      MockHttpClient.put_response(
        "ISBN:#{isbn}",
        {:ok, %{"ISBN:#{isbn}" => %{"title" => "An Edition", "authors" => [%{"name" => "Eco"}]}}}
      )
    end)
  end

  defp edition_isbns(book_id) do
    Repo.all(from e in BookEdition, where: e.book_id == ^book_id, select: e.isbn)
  end

  describe "perform/1" do
    test "records the work's other editions", %{book: book} do
      stub_resolve("OL27448W")
      stub_editions([@primary, "9788497592581", "9780099466031"])

      assert :ok = perform_job(DiscoverEditionsJob, %{"book_id" => book.id})

      isbns = edition_isbns(book.id)

      assert "9788497592581" in isbns
      assert "9780099466031" in isbns
    end

    test "does not duplicate the edition we already hold", %{book: book} do
      # The primary ISBN is in the work's own edition list, so it comes back every time.
      stub_resolve("OL27448W")
      stub_editions([@primary, "9788497592581"])

      assert :ok = perform_job(DiscoverEditionsJob, %{"book_id" => book.id})

      assert Enum.count(edition_isbns(book.id), &(&1 == @primary)) == 1,
             "the primary edition was inserted a second time"
    end

    test "caps how many editions one run creates", %{book: book} do
      # Twenty offered, ten allowed. Uncapped this is one resolver race per ISBN per new
      # book — the fan-out the cap exists to bound.
      offered = for i <- 1..20, do: isbn13(i)

      stub_resolve("OL27448W")
      stub_editions(offered)

      assert :ok = perform_job(DiscoverEditionsJob, %{"book_id" => book.id})

      # +1 for the primary edition created in setup.
      created = length(edition_isbns(book.id)) - 1

      assert created <= 10,
             "expected at most 10 editions created in one run, got #{created}"
    end

    test "a re-run does not spend its budget on editions it already created", %{book: book} do
      offered = for i <- 1..20, do: isbn13(i)

      stub_resolve("OL27448W")
      stub_editions(offered)

      assert :ok = perform_job(DiscoverEditionsJob, %{"book_id" => book.id})
      first_run = length(edition_isbns(book.id))

      assert :ok = perform_job(DiscoverEditionsJob, %{"book_id" => book.id})
      second_run = length(edition_isbns(book.id))

      assert second_run > first_run,
             "a second run rediscovered nothing — known ISBNs are not being skipped, " <>
               "so the cap is spent re-attempting rows that already exist"
    end

    test "a work with no editions is not a failure", %{book: book} do
      stub_resolve("OL27448W")
      stub_editions([])

      assert :ok = perform_job(DiscoverEditionsJob, %{"book_id" => book.id})
    end

    test "an ISBN that resolves to no Open Library work is not a failure", %{book: book} do
      # Google Books can satisfy a resolve without any OL work key. That is a normal
      # outcome, not a broken job.
      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok, %{"ISBN:#{@primary}" => %{"title" => "The Name of the Rose"}}}
      )

      assert :ok = perform_job(DiscoverEditionsJob, %{"book_id" => book.id})
      assert edition_isbns(book.id) == [@primary]
    end

    test "a book with no primary edition is skipped rather than crashing" do
      orphan = insert(:book, title: "No Editions Yet")
      assert :ok = perform_job(DiscoverEditionsJob, %{"book_id" => orphan.id})
    end

    test "cancels on malformed args" do
      assert {:cancel, "invalid args"} = perform_job(DiscoverEditionsJob, %{})
    end

    test "an ISBN Open Library lists but cannot verify is refused by the hard gate", %{
      book: book
    } do
      # Open Library's edition entries are user-contributed and include ISBNs that no
      # upstream can resolve. `Books.merge_edition/2` re-resolves each one, so those are
      # refused — no book enters the system on an unverified ISBN, even via this path.
      # This is the behaviour that made the first draft of these tests look broken.
      stub_resolve("OL27448W")

      MockHttpClient.put_response(
        "openlibrary.org/works",
        {:ok, %{"entries" => [%{"isbn_13" => ["9999999999999"]}]}}
      )

      assert :ok = perform_job(DiscoverEditionsJob, %{"book_id" => book.id})

      assert edition_isbns(book.id) == [@primary],
             "an unverifiable ISBN was recorded — the ISBN hard gate was bypassed"
    end
  end
end
