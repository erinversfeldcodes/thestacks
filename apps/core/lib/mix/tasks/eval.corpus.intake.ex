defmodule Mix.Tasks.Eval.Corpus.Intake do
  @shortdoc "Turn dropped photographs into labelled corpus rows"

  @moduledoc """
  Reads the photographs in `images/` and reports what the eval corpus can and
  cannot score, deriving each one's stratum from its filename prefix and its
  identity from the rest of the name.

  ⛔ **The identity must be in the filename, because labelling afterwards is what
  broke the first corpus.** Seven of the original eight fixtures carry no
  expected ISBN, and `isbn_ok` passes when the expectation is nil — so their
  identity could not fail, whatever the model answered, and `recall@1` was
  uncomputable at any corpus size. Growing the corpus the same way would have
  added more unfalsifiable rows.

  ⚖️ This task **reports**; it does not rewrite `vision_corpus.exs`. A generated
  corpus file would overwrite the hand-written comments that record why a label
  is what it is — including the one documenting that the plan once cited Bird
  Lake Moon's ISBN for The Name of the Rose. Those comments are the corpus's
  memory, so the task prints rows to paste rather than taking the file over.

  See `images/CORPUS-INTAKE.md` for the shooting brief.
  """

  use Mix.Task

  # Prefix → {stratum, target n, whether a book identity is expected}
  @strata %{
    "clean" => {:clean_barcode, 20, true},
    "hostile" => {:hostile_barcode, 20, true},
    "cover" => {:clear_cover, 25, true},
    "typo" => {:hostile_typography, 20, true},
    "multi" => {:multiple_books, 15, true},
    "neg" => {:negative, 20, false},
    "adjacent" => {:book_adjacent, 15, false}
  }

  # ⛔ PROVENANCE IS NOT BOILERPLATE. The corpus test that reads this field is
  # the one defending the no-user-images rule: every image must be traceable to
  # the owner or to a transform of an owner image, forever. A row without it
  # scores perfectly well and leaves nobody able to answer "where did this come
  # from?" once the person who added it has forgotten.
  #
  # ⚠️ Defined HERE rather than beside its use, because an attribute referenced
  # before definition is `nil`, and `"#{nil}"` is the empty string — so a
  # misplaced definition emits `captured: ""` on every row and nothing fails.
  @captured "2026-11-13"

  # Generated from clean originals rather than shot — see the plan's §4.2.
  #
  # ⬛ A derived image INHERITS its source's identity, which is the whole reason
  # these two strata can be generated: no identity is invented, so no label can
  # lie. The transform rides in the filename so a synthetic failure is never
  # read as a real-world one.
  #
  # ⚠️ `expect_book` differs between them, and the difference is the point.
  # A mirrored barcode IS still a decodable book — pyzbar cannot read it, but
  # the mirror-and-retry path should, so the true ISBN remains the expected
  # answer. A deliberately illegible image is the safety case: the plan asks
  # that the system "declines rather than guesses", and `expect_book: false` is
  # the only way this schema can express a decline. ⚠️ That is a slight abuse of
  # the field — the subject IS a book — and it is recorded here rather than
  # left for a reader to infer from a surprising label.
  @synthetic %{
    "mirrored" => {:hostile_orientation, 10, true},
    "illegible" => {:illegible, 10, false}
  }

  @impl Mix.Task
  def run(argv) do
    dir = Path.join(root(), "images")
    files = known_files(dir)

    {parsed, unparsed} =
      files
      |> Enum.map(&parse/1)
      |> Enum.reject(fn {status, _, _} -> status == :legacy end)
      |> Enum.split_with(fn {status, _, _} -> status == :ok end)

    report(parsed, unparsed)
    if "--rows" in argv, do: print_rows(parsed)
    :ok
  end

  @doc """
  Derives `{:ok, stratum, identity}` from a filename, or `{:error, name, why}`.

  `identity` is `{:isbn, "978…"}`, `{:title, "flyboys"}`, or `:none` for the
  rejection strata, which need no identity and must not be asked for one.
  """
  # ⚠️ The eight original fixtures predate this naming convention and are
  # already hand-labelled in `vision_corpus.exs`, with comments recording why
  # each label is what it is. Reporting them as unreadable would be noise that
  # trains the reader to ignore the unreadable list — which is where a genuinely
  # mis-named new photograph will appear.
  @pre_existing ~w(
    barcode_isbn_clean.jpg not_a_book.jpg negative_non_isbn_barcode.jpg
    negative_text_document.jpg screenshot_image_reversed.jpg
    screenshot_image_reversed_and_cut_off.jpg screenshot_mildly_obscured.jpg
    screenshot_mixed_text.jpg
  )

  def parse(name) when name in @pre_existing, do: {:legacy, name, "hand-labelled already"}

  def parse(name) do
    base = Path.rootname(Path.basename(name))

    case String.split(base, "-", parts: 2) do
      [prefix, rest] when rest != "" ->
        classify(prefix, rest, name)

      _ ->
        {:error, name, "no `prefix-rest` shape; see images/CORPUS-INTAKE.md"}
    end
  end

  defp classify(prefix, rest, name) do
    case Map.fetch(@strata, prefix) do
      {:ok, {stratum, _target, needs_identity}} ->
        {:ok, {stratum, identity(rest, needs_identity)}, name}

      :error ->
        derived(prefix, rest, name)
    end
  end

  # A derived image carries its source's ISBN, so it is asked for an identity
  # exactly as its original was.
  defp derived(prefix, rest, name) do
    case Map.fetch(@synthetic, prefix) do
      {:ok, {stratum, _target, expects_book}} ->
        {:ok, {stratum, identity(rest, expects_book)}, name}

      :error ->
        {:error, name, "unknown stratum prefix #{inspect(prefix)}"}
    end
  end

  # ⚠️ An ISBN is taken only from a 13-digit run, never inferred from a title.
  # A photograph is of one physical copy, so its ISBN is that edition's and
  # cannot be derived from the work's name — deriving one reproduces the
  # defect this corpus already documents.
  defp identity(_rest, false), do: :none

  defp identity(rest, true) do
    case Regex.run(~r/\b(97[89]\d{10})\b/, rest) do
      [_, isbn] -> {:isbn, isbn}
      nil -> title_or_nothing(rest)
    end
  end

  defp title_or_nothing(rest) do
    slug =
      rest
      |> String.replace(~r/[^A-Za-z0-9]+/, " ")
      |> String.trim()

    if slug == "" or Regex.match?(~r/^\d+$/, slug) do
      :none
    else
      {:title, slug}
    end
  end

  defp report(parsed, unparsed) do
    counts =
      parsed
      |> Enum.group_by(fn {:ok, {stratum, _}, _} -> stratum end)
      |> Map.new(fn {k, v} -> {k, length(v)} end)

    Mix.shell().info("\n=== strata (you shoot these) ===")

    @strata
    |> Enum.sort_by(fn {_, {_, target, _}} -> -target end)
    |> Enum.each(fn {prefix, {stratum, target, _}} ->
      have = Map.get(counts, stratum, 0)
      Mix.shell().info(pad("#{prefix}-", 12) <> progress(have, target))
    end)

    Mix.shell().info("\n=== generated from clean originals ===")

    Enum.each(@synthetic, fn {name, {stratum, target, _}} ->
      have = Map.get(counts, stratum, 0)
      note = if have == 0, do: "  (not yet generated)", else: ""
      Mix.shell().info(pad("#{name}", 12) <> progress(have, target) <> note)
    end)

    identified =
      Enum.count(parsed, fn {:ok, {_, identity}, _} -> identity != :none end)

    needs_identity =
      Enum.count(parsed, fn {:ok, {stratum, _}, _} -> book_stratum?(stratum) end)

    shot_strata = @strata |> Map.values() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    shot =
      counts
      |> Enum.filter(fn {s, _} -> s in shot_strata end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    derived = Enum.sum(Map.values(counts)) - shot
    target_total = @strata |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    Mix.shell().info("\n=== totals ===")
    Mix.shell().info("shot                 #{shot}/#{target_total}")
    Mix.shell().info("derived              #{derived} generated from clean originals")
    Mix.shell().info("pre-existing         #{length(@pre_existing)} hand-labelled fixtures")
    Mix.shell().info("recall-usable        #{identified}/#{needs_identity} carry an identity")

    # ⛔ A photograph with no identity cannot score recall. Reported as a
    # shortfall rather than a count, because the count alone reads as progress.
    missing = needs_identity - identified

    if missing > 0 do
      Mix.shell().info(
        "\n⚠️  #{missing} book photo(s) carry no ISBN or title, so they cannot score " <>
          "identity.\n    Rename them per images/CORPUS-INTAKE.md — this is the gap that " <>
          "made recall@1\n    uncomputable on the first corpus."
      )
    end

    unless unparsed == [] do
      Mix.shell().info("\n=== could not read (#{length(unparsed)}) ===")
      Enum.each(unparsed, fn {:error, name, why} -> Mix.shell().info("  #{name} — #{why}") end)
    end
  end

  defp print_rows(parsed) do
    Mix.shell().info("\n=== rows for vision_corpus.exs ===")

    Enum.each(parsed, fn {:ok, {stratum, identity}, name} ->
      Mix.shell().info("""
        %{
          name: "#{Path.rootname(name)}",
          path: "images/#{name}",
          stratum: :#{stratum},
          expect_book: #{book_stratum?(stratum)},
          #{identity_field(identity)},
          provenance: %{
            photographer: "#{provenance_for(stratum)}",
            captured: "#{@captured}",
            source: :#{source_for(stratum)}
          },
          notes: "#{notes_for(stratum)}"
        },\
      """)
    end)
  end

  # ⛔ `:owned` or `:synthetic`, and the corpus guard admits nothing else. This
  # is the field that makes the no-user-images rule checkable rather than
  # merely stated: a third value, or an absent one, is how an image of unknown
  # origin would enter a corpus that is forever.
  defp source_for(stratum) do
    if Enum.any?(@synthetic, fn {_, {s, _, _}} -> s == stratum end),
      do: :synthetic,
      else: :owned
  end

  defp provenance_for(stratum) do
    if Enum.any?(@synthetic, fn {_, {s, _, _}} -> s == stratum end),
      do: "generated",
      else: "owner"
  end

  # ⚠️ Each note stays under ~80 characters so the emitted line fits what
  # `mix format` accepts without wrapping. A generator whose output its own
  # formatter rewrites produces a diff on every regeneration, and the real
  # change gets lost in it.
  #
  # ⬛ The note says what the STRATUM tests, and nothing about the identity —
  # `expect_isbn` and `expect_title` already say which of those was readable,
  # and a note restating them is a second place to keep in step.
  #
  # ⚖️ A lookup rather than a `case`: these are data, and as a function head
  # per stratum they were ten branches that credo counts as logic.
  @notes %{
    clean_barcode: "Back cover, barcode sharp and face-on. The cheap path's control.",
    hostile_barcode: "Barcode present but hard: angled, dim, covered or rotated.",
    clear_cover: "Front cover, no barcode. Identification without scanning.",
    hostile_typography: "Title hard to read as text: drawn, decorative or lost in design.",
    multiple_books: "Several books in one frame.",
    negative: "Not a book. A false accept here is worse than a false reject.",
    book_adjacent: "Book-shaped but not a book. The hardest rejection case.",
    hostile_orientation: "Mirrored or rotated; pyzbar cannot decode a mirrored barcode.",
    illegible: "Blurred or underexposed. Must decline rather than guess."
  }

  defp notes_for(stratum), do: Map.get(@notes, stratum, "Owner-authored corpus image.")

  # ⚠️ Includes the DERIVED strata: a mirrored barcode is still a book, and an
  # illegible one is deliberately not — see `@synthetic`, where that difference
  # is the third element of each tuple.
  # ⛔ AN ISBN OR A TITLE, NEVER BOTH AND NEVER DERIVED FROM EACH OTHER. The
  # ISBN comes off a barcode whose check digit verified; the title comes off a
  # cover whose barcode did not. Inferring one from the other is the error this
  # corpus already records — the plan once cited Bird Lake Moon's ISBN for a
  # fixture that is The Name of the Rose, and the note says "the model was
  # right where this label was wrong".
  #
  # ⚠️ Four spaces on the continuation, matching the surrounding map keys, so
  # `mix format` leaves the emitted row alone.
  defp identity_field({:isbn, isbn}), do: ~s|expect_isbn: "#{isbn}"|

  defp identity_field({:title, title}),
    do: ~s|expect_isbn: nil,\n    expect_title: "#{title}"|

  defp identity_field(:none), do: "expect_isbn: nil"

  defp book_stratum?(stratum) do
    Enum.any?(@strata, fn {_, {s, _, needs}} -> s == stratum and needs end) or
      Enum.any?(@synthetic, fn {_, {s, _, expects}} -> s == stratum and expects end)
  end

  defp known_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&(Path.extname(&1) in [".jpg", ".jpeg", ".png"]))
        |> Enum.sort()

      {:error, reason} ->
        Mix.raise("cannot read #{dir}: #{inspect(reason)}")
    end
  end

  defp progress(have, target) do
    bar = String.duplicate("#", min(have, target))
    "#{have}/#{target}  #{bar}"
  end

  defp pad(s, n), do: String.pad_trailing(s, n)

  defp root do
    Enum.reduce_while(0..6, File.cwd!(), fn _, dir ->
      if File.dir?(Path.join(dir, "images")),
        do: {:halt, dir},
        else: {:cont, Path.expand("..", dir)}
    end)
  end
end
