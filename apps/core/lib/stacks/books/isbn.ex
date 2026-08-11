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

    if valid_isbn10?(normalised) do
      to_isbn13(normalised)
    else
      normalised
    end
  end

  def canonical_isbn13(_isbn), do: nil

  defp valid_isbn10?(isbn) do
    isbn =~ ~r/^\d{9}[\dX]$/ and isbn10_check_digit_ok?(isbn)
  end

  defp isbn10_check_digit_ok?(<<first_nine::binary-size(9), check>>) do
    sum =
      first_nine
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc -> acc + d * (10 - i) end)

    expected = rem(11 - rem(sum, 11), 11)
    actual = if check == ?X, do: 10, else: check - ?0
    expected == actual
  end

  @doc """
      Normalises an ISBN-10 to its ISBN-13 equivalent so DB lookups always use
      the canonical form. ISBN-13s (and anything else) are returned unchanged.

      Unlike `canonical_isbn13/1` this neither strips separators nor checks the
      ISBN-10's own check digit — it rewrites any 10-byte binary. `Stacks.Books`
      uses it on already-shape-validated input (the edition changeset, after
      `validate_format/3` and the checksum validation) and on lookup keys in
      `find_existing/1`; anywhere else, `canonical_isbn13/1` is the safer choice.
  """
  @spec to_isbn13(term()) :: term()
  def to_isbn13(<<a, b, c, d, e, f, g, h, i, _check>>) do
    nine = [a - ?0, b - ?0, c - ?0, d - ?0, e - ?0, f - ?0, g - ?0, h - ?0, i - ?0]
    prefix = [9, 7, 8 | nine]
    weights = [1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3]

    sum =
      Enum.zip(prefix, weights)
      |> Enum.reduce(0, fn {d, w}, acc -> acc + d * w end)

    check = rem(10 - rem(sum, 10), 10)
    "978" <> <<a, b, c, d, e, f, g, h, i>> <> Integer.to_string(check)
  end

  def to_isbn13(isbn), do: isbn
end
