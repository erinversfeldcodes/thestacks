defmodule Stacks.SeedHonestyTest do
  @moduledoc """
  Issue #339 — the seed may only write editions a production write path could.

  The sibling of `factory_honesty_test.exs` (#329). The seed is the *other*
  fixture that goes around every changeset: it writes editions with
  `Repo.insert_all/3` for deterministic ids and fixed timestamps, and bought a
  bypass of every ISBN validation along with them. Three editions with wrong
  EAN-13 check digits reached staging that way and were only discovered when a
  CHECK constraint tried to validate — months later, mid-deploy.

  Two guards, because the owner's ruling had two halves: the values in the file
  must be right, and the path must be unable to write wrong ones.
  """
  use Core.DataCase, async: true

  alias Stacks.Books
  alias Stacks.Books.BookEdition
  alias Stacks.Books.ISBN
  alias Stacks.DataCorrection.StaleSeedEditionIsbn

  @seeds_path Path.expand("../../priv/repo/seeds.exs", __DIR__)

  # `{1076, "9780156030359", "A Room of One's Own", 108, …}` — index, then ISBN.
  @edition_tuple ~r/^\s*\{\d+,\s*"(\d+)"/m

  defp seeds_source, do: File.read!(@seeds_path)

  defp seeded_isbns do
    @edition_tuple
    |> Regex.scan(seeds_source())
    |> Enum.map(fn [_line, isbn] -> isbn end)
  end

  describe "the values in seeds.exs" do
    test "the ISBN literals are actually found (this test can fail)" do
      # Without this the regex could silently stop matching and every assertion
      # below would pass over an empty list.
      assert length(seeded_isbns()) > 150
    end

    test "every seeded ISBN is thirteen digits with a valid EAN-13 check digit" do
      bad =
        Enum.reject(seeded_isbns(), fn isbn ->
          String.length(isbn) == 13 and ISBN.valid_isbn_checksum?(isbn)
        end)

      assert bad == [],
             "seeds.exs declares ISBNs that no write path could store: #{inspect(bad)}"
    end

    test "every seeded ISBN is unique" do
      isbns = seeded_isbns()
      duplicates = isbns -- Enum.uniq(isbns)

      assert duplicates == [], "duplicate seed ISBNs: #{inspect(duplicates)}"
    end

    test "the edition rows are vetted before insert_all/3 sees them" do
      source = seeds_source()

      assert source =~ "Stacks.Books.vet_edition_row!(%{"
      assert source =~ ~s(Repo.insert_all("book_editions", edition_rows)
    end
  end

  describe "the correction's fixture table mirrors seeds.exs" do
    test "each corrected value is the one seeds.exs now declares" do
      source = seeds_source()

      for {_id, from, to} <- StaleSeedEditionIsbn.fixtures() do
        assert source =~ to, "seeds.exs no longer declares #{to} — the correction has drifted"
        refute source =~ from, "seeds.exs still declares the broken literal #{from}"
      end
    end
  end

  describe "Books.vet_edition_row!/1 — the gate itself" do
    defp row(overrides) do
      Map.merge(
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          book_id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          isbn: "9780141036144",
          is_primary: true,
          verification_source: "open_library",
          created_at: ~U[2026-01-01 00:00:00.000000Z],
          updated_at: ~U[2026-01-01 00:00:00.000000Z]
        },
        overrides
      )
    end

    test "passes a good row through unchanged" do
      given = row(%{})

      assert Books.vet_edition_row!(given) == given
    end

    test "rejects each of the three literals that actually reached staging" do
      for {_id, broken, _fixed} <- StaleSeedEditionIsbn.fixtures() do
        assert_raise ArgumentError, ~r/not one a production write path could produce/, fn ->
          Books.vet_edition_row!(row(%{isbn: broken}))
        end
      end
    end

    test "normalises an ISBN-10 literal to its ISBN-13 form" do
      vetted = Books.vet_edition_row!(row(%{isbn: "0071615695"}))

      assert vetted.isbn == "9780071615693"
    end

    test "rejects a row with no provenance" do
      assert_raise ArgumentError, fn ->
        Books.vet_edition_row!(row(%{}) |> Map.delete(:verification_source))
      end
    end

    test "rejects a provenance outside the closed set" do
      assert_raise ArgumentError, fn ->
        Books.vet_edition_row!(row(%{verification_source: "vibes"}))
      end
    end

    test "rejects a non-ISBN string" do
      assert_raise ArgumentError, fn -> Books.vet_edition_row!(row(%{isbn: "not-an-isbn"})) end
    end

    test "what it returns is what the database accepts" do
      book = Stacks.Factory.insert(:editionless_book)

      vetted =
        Books.vet_edition_row!(row(%{isbn: "0062028510", book_id: Ecto.UUID.dump!(book.id)}))

      # The string table name, exactly as seeds.exs writes it — that is the call
      # whose rows are unchecked, so it is the call this has to survive.
      assert {1, _} = Core.Repo.insert_all("book_editions", [vetted], prefix: "op")
      assert Core.Repo.get_by(BookEdition, isbn: "9780062028518")
    end
  end
end
