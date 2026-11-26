defmodule Mix.Tasks.Eval.Corpus.IntakeTest do
  @moduledoc """
  ⛔ The filename IS the ground truth, so a parsing slip is a mislabelled corpus
  row — and a mislabelled row is worse than a missing one, because it scores.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Eval.Corpus.Intake

  describe "reading an identity off a filename" do
    test "a 13-digit run is taken as the ISBN" do
      assert {:ok, {:clean_barcode, {:isbn, "9780156001311"}}, _} =
               Intake.parse("clean-9780156001311.jpg")
    end

    test "a restaging carries the same identity as its clean original" do
      assert {:ok, {:hostile_barcode, {:isbn, "9780156001311"}}, _} =
               Intake.parse("hostile-9780156001311-angled.jpg")
    end

    test "a name with no ISBN becomes a title, which is a weaker claim" do
      assert {:ok, {:clear_cover, {:title, "flyboys"}}, _} = Intake.parse("cover-flyboys.jpg")

      assert {:ok, {:hostile_typography, {:title, "train to crystal city"}}, _} =
               Intake.parse("typo-train-to-crystal-city.jpg")
    end

    # ⛔ An ISBN must NEVER be inferred from a title. A photograph is of one
    # physical copy, so its ISBN is that edition's; the work has many. This
    # corpus already documents the cost of that inference — the plan cited Bird
    # Lake Moon's ISBN for a fixture that is The Name of the Rose.
    test "a title never yields an ISBN" do
      assert {:ok, {:clear_cover, {:title, "flyboys"}}, _} = Intake.parse("cover-flyboys.jpg")
      refute match?({:ok, {_, {:isbn, _}}, _}, Intake.parse("cover-flyboys.jpg"))
    end

    test "the rejection strata are not asked for an identity" do
      assert {:ok, {:negative, :none}, _} = Intake.parse("neg-a-mug.jpg")
      assert {:ok, {:book_adjacent, :none}, _} = Intake.parse("adjacent-magazine.jpg")
    end

    # ⚠️ A book photo whose name carries no identity must come back `:none` so
    # the task REPORTS it. Guessing one, or treating it as fine, is how the
    # first corpus ended up with 7 of 8 rows that could not fail.
    test "a camera-default name yields no identity rather than a guess" do
      assert {:ok, {:clear_cover, :none}, _} = Intake.parse("cover-4817.jpg")
    end

    test "an unknown prefix is reported, not guessed into a stratum" do
      assert {:error, _, why} = Intake.parse("sideways-9780156001311.jpg")
      assert why =~ "unknown stratum prefix"
    end

    test "a name with no prefix shape is reported" do
      assert {:error, _, why} = Intake.parse("IMG_4817.jpg")
      assert why =~ "prefix-rest"
    end

    # The eight originals are hand-labelled with comments recording why; they
    # must not appear in the unreadable list, which is where a genuinely
    # mis-named NEW photograph needs to be visible.
    test "the pre-existing fixtures are recognised, not reported as broken" do
      assert {:legacy, _, _} = Intake.parse("barcode_isbn_clean.jpg")
      assert {:legacy, _, _} = Intake.parse("screenshot_mixed_text.jpg")
    end

    # ⚠️ KNOWN LIMITATION, asserted so it cannot change silently: a multi-book
    # frame records only its FIRST ISBN, because `expect_isbn` is a single
    # field. Making it list-valued is a harness change; faking it with one
    # field would be a row claiming one book when the truth is several.
    test "a multi-book frame keeps only the first ISBN" do
      assert {:ok, {:multiple_books, {:isbn, "9780156001311"}}, _} =
               Intake.parse("multi-9780156001311-9781234567897.jpg")
    end
  end
end
