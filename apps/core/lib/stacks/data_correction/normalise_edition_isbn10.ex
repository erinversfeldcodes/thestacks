defmodule Stacks.DataCorrection.NormaliseEditionIsbn10 do
  @moduledoc """
      Rewrites editions still holding an ISBN-10 into the ISBN-13 the column
      has always meant. The changeset has normalised on write only since
      2026-05-15; older rows kept whatever form the caller supplied, invisible
      because 13-form lookups simply return nothing. Conversion is arithmetic
      (`ISBN.canonical_isbn13/1` — the same function `find_existing/1`
      compares with, so repaired rows become findable). Plan selects only
      checksum-valid ISBN-10s; anything else is left for a human.
  """

  @behaviour Stacks.DataCorrection

  alias Stacks.Books.ISBN
  alias Stacks.DataCorrection.EditionIsbn

  @impl true
  def name, do: "normalise_edition_isbn10"

  @impl true
  def resource_type, do: "book_edition"

  @impl true
  def scope,
    do: "op.book_editions rows whose isbn is 10 digits with a valid ISBN-10 check digit"

  @impl true
  def reversibility,
    do:
      {:reversible,
       "the ISBN-10 is recoverable from the ISBN-13 by arithmetic, and the audit row keeps it — " <>
         "but nothing should reverse it: the column has always meant ISBN-13"}

  @impl true
  def plan do
    "^[0-9]{10}$"
    |> EditionIsbn.matching()
    |> Enum.filter(fn {_id, isbn} -> ISBN.valid_isbn_checksum?(isbn) end)
    |> Enum.map(fn {id, isbn} ->
      %{
        id: id,
        from: isbn,
        to: ISBN.canonical_isbn13(isbn),
        because: "ISBN-10 stored unnormalised; converted to its ISBN-13 equivalent"
      }
    end)
  end

  @impl true
  def apply_change(%{id: id, from: from, to: to}), do: EditionIsbn.swap(id, from, to)
end
