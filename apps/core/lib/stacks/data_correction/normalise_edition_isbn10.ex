defmodule Stacks.DataCorrection.NormaliseEditionIsbn10 do
  @moduledoc """
  Rewrites editions still holding an ISBN-10 into the ISBN-13 form the column
  has always meant (Issue #339).

  `Stacks.Books.book_edition_changeset/2` accepts an ISBN-10 and normalises it
  to ISBN-13 before storage — but only since 2026-05-15 (the commit that added
  `normalize_edition_isbn/1`). Rows written before that kept whatever form the
  caller supplied, so production carries two editions whose `isbn` is a
  perfectly valid ISBN-10 sitting in a column every reader treats as ISBN-13.
  Nothing noticed, because a lookup by the 13-form simply returns nothing.

  The conversion is arithmetic, not a lookup: prefix `978`, keep the first nine
  digits, discard the ISBN-10 check digit (it does not carry over) and recompute
  the EAN-13 check digit over the resulting twelve. `Stacks.Books.canonical_isbn13/1`
  is that function, and is the same one `find_existing/1` compares against — so a
  repaired row becomes findable by the identity the rest of the system already uses.

  ## Scope

  Editions whose `isbn` is exactly ten digits **and** whose ISBN-10 check digit
  is valid. A ten-digit string with a bad check digit is not an ISBN-10 and has
  no derivable correct value; it is left alone and reported rather than guessed
  at.
  """

  @behaviour Stacks.DataCorrection

  alias Stacks.Books
  alias Stacks.DataCorrection.EditionIsbn

  @impl true
  def name, do: "normalise_edition_isbn10"

  @impl true
  def resource_type, do: "book_edition"

  @impl true
  def scope,
    do: "op.book_editions rows whose isbn is 10 digits with a valid ISBN-10 check digit"

  @impl true
  def plan do
    "^[0-9]{10}$"
    |> EditionIsbn.matching()
    |> Enum.filter(fn {_id, isbn} -> Books.valid_isbn_checksum?(isbn) end)
    |> Enum.map(fn {id, isbn} ->
      %{
        id: id,
        from: isbn,
        to: Books.canonical_isbn13(isbn),
        because: "ISBN-10 stored unnormalised; converted to its ISBN-13 equivalent"
      }
    end)
  end

  @impl true
  def apply_change(%{id: id, from: from, to: to}), do: EditionIsbn.swap(id, from, to)
end
