defmodule Stacks.Books.ISBN do
  @moduledoc """
      ISBN arithmetic: check digits and the ISBN-10 → ISBN-13 canonical form.

      Pure functions over strings — no repo, no context, no configuration. That is
      the whole point of the module: the ISBN hard gate leans on these answers from
      the changeset layer, the moderation fast path, the resolver, the title-search
      cache and a data-correction script, and none of those callers should have to
      reach through a 1,700-line context to ask whether a check digit is right.

      Extracted verbatim from `Stacks.Books`. `to_isbn13/1` is public here
      because it always had callers outside the arithmetic — it was reachable only
      because they happened to share a module.
  """

  @doc """
      True iff `isbn` is a well-formed ISBN-10 or ISBN-13 with a valid
      check digit. Strings that don't match the shape are accepted (returns
      `true`) so validation callsites can defer shape-checking to separate
      validators; for explicit checksum gating, pre-filter with the shape
      regex before calling.

      Publicly exposed so callers (e.g. `Stacks.Moderation`) can trust a
      scanner-decoded ISBN without a round-trip to Open Library: barcode
      scanners won't decode a checksum-invalid EAN-13, and the 1-in-10 odds
      of a random 13-digit string passing the checksum make false positives
      vanishingly rare.
  """
  @spec valid_isbn_checksum?(String.t()) :: boolean()
  def valid_isbn_checksum?(isbn) do
    if isbn =~ ~r/^\d{10}$|^\d{13}$/ do
      digits = Enum.map(String.graphemes(isbn), &String.to_integer/1)

      case length(digits) do
        13 -> isbn13_valid?(digits)
        10 -> isbn10_valid?(digits)
        _ -> false
      end
    else
      true
    end
  end

  defp isbn13_valid?(digits) do
    sum =
      digits
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc ->
        weight = if rem(i, 2) == 0, do: 1, else: 3
        acc + d * weight
      end)

    rem(sum, 10) == 0
  end

  defp isbn10_valid?(digits) do
    sum =
      digits
      |> Enum.take(9)
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc -> acc + d * (10 - i) end)

    check = rem(11 - rem(sum, 11), 11)
    check != 10 and check == Enum.at(digits, 9)
  end

  @doc """
      Canonical ISBN-13 comparison form: strips hyphens/whitespace, upcases,
      and converts a checksum-valid ISBN-10 (incl. `X`) to ISBN-13 (`978` +
      nine digits + recomputed EAN-13 check digit; the ISBN-10 check digit
      does not carry). Anything else returns stripped/upcased unchanged;
      non-binary returns `nil`. Two strings identify the same edition iff
      canonical forms are equal — use on BOTH sides of any comparison: OL/GB
      docs often carry only ISBN-10 while `book_editions.isbn` is always 13,
      so bare stripped equality misses cross-form matches.
  """
  @spec canonical_isbn13(term()) :: String.t() | nil
  def canonical_isbn13(isbn) when is_binary(isbn) do
    normalised =
      isbn
      |> String.replace(~r/[\s-]/, "")
      |> String.upcase()

    case to_isbn13(normalised) do
      {:ok, isbn13} -> isbn13
      {:error, :invalid_isbn10_checksum} -> normalised
    end
  end

  def canonical_isbn13(_isbn), do: nil

  defp isbn10_shaped?(isbn), do: isbn =~ ~r/^\d{9}[\dXx]$/

  defp isbn10_check_digit_ok?(<<first_nine::binary-size(9), check>>) do
    sum =
      first_nine
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc -> acc + d * (10 - i) end)

    expected = rem(11 - rem(sum, 11), 11)
    actual = if check in [?X, ?x], do: 10, else: check - ?0
    expected == actual
  end

  @doc """
      Normalises an ISBN-10 to its ISBN-13 equivalent so DB lookups always use
      the canonical form: `{:ok, "978" <> the nine digits <> a recomputed EAN-13
      check digit}`. ISBN-13s — and anything not shaped like an ISBN-10 — come
      back unchanged as `{:ok, isbn}`.

      An ISBN-10 whose OWN check digit is wrong is REFUSED with
      `{:error, :invalid_isbn10_checksum}`. It must never be converted: the
      EAN-13 check digit is recomputed from the first nine digits, so the result
      of converting a bad ISBN-10 is a structurally perfect ISBN-13 that nothing
      downstream — not the changeset's checksum validation, not the database's
      EAN-13 CHECK constraint — can tell from a real one. Conversion is the last
      moment the original check digit exists to be judged, so it is where the
      judgement has to happen.

      Unlike `canonical_isbn13/1` this does not strip separators or upcase.
  """
  @spec to_isbn13(term()) :: {:ok, term()} | {:error, :invalid_isbn10_checksum}
  def to_isbn13(isbn) when is_binary(isbn) do
    cond do
      not isbn10_shaped?(isbn) -> {:ok, isbn}
      isbn10_check_digit_ok?(isbn) -> {:ok, ean13_from_isbn10(isbn)}
      true -> {:error, :invalid_isbn10_checksum}
    end
  end

  def to_isbn13(isbn), do: {:ok, isbn}

  defp ean13_from_isbn10(<<first_nine::binary-size(9), _check>>) do
    weights = [1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3]

    sum =
      [9, 7, 8 | Enum.map(String.graphemes(first_nine), &String.to_integer/1)]
      |> Enum.zip(weights)
      |> Enum.reduce(0, fn {d, w}, acc -> acc + d * w end)

    check = rem(10 - rem(sum, 10), 10)
    "978" <> first_nine <> Integer.to_string(check)
  end
end
