defmodule Stacks.ModerationTelemetryTest do
  @moduledoc """
  Firing tests for the moderation-funnel operational counters added in
  Issue #228 (US-4.1 §13, epic #118).

  Verifies each step of the moderation pipeline emits a `[:stacks,
  :moderation, …]` telemetry event with the right measurements and
  metadata:

  - step 1 classification outcome — `:book` / `:not_a_book` / `:ambiguous`
  - step 2 ISBN resolution outcome — `:resolved` / `:isbn_not_found`
  - step 3 age-gate tiering — `:public` / `:age_gated`
  - compound-title expansion — split frequency + parts

  Metadata tags are whitelisted atoms only — never a raw ISBN, title, or
  any other user input (GDPR: telemetry is a warehouse-adjacent sink).

  Follows the attach → exercise → assert_receive pattern of
  `upload_telemetry_test.exs` / `visibility_telemetry_test.exs`.
  """

  # async: false — swaps the vision client via Application.put_env (global
  # process state) and attaches global telemetry handlers.
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.AI.VisionFixtures
  import Stacks.Factory

  alias Stacks.Books
  alias Stacks.Moderation

  @test_image_b64 Base.encode64("fake image bytes")

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = "test-moderation-tel-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # A candidate whose title is two book titles joined with " OR " — exercises
  # expand_compound_candidates/1.
  defp compound_title_text do
    book_response([book_candidate(title: "First Book OR Second Book", confidence: 0.9)])
  end

  # BOOK classification with a candidate that has no ISBN and a nil title —
  # title_fallback returns :isbn_not_found for it.
  defp no_resolvable, do: book_response([book_candidate()])

  # ── Step 1: classification outcome ─────────────────────────────────────

  describe "classification telemetry" do
    test "emits :book when the image is classified as a book (happy)" do
      attach_telemetry([[:stacks, :moderation, :classification]])

      context = %{image_b64: @test_image_b64, book_attrs: %{"title" => "The Great Gatsby"}}
      assert {:ok, %{resolved: [_book]}} = Moderation.run_pipeline(context)

      assert_receive {:telemetry_event, [:stacks, :moderation, :classification], %{count: 1},
                      %{outcome: :book}}
    end

    test "emits :not_a_book when the image is not a book (sad)" do
      attach_telemetry([[:stacks, :moderation, :classification]])

      with_vision(not_a_book(), fn ->
        assert {:error, :not_a_book} = Moderation.run_pipeline(%{image_b64: @test_image_b64})
      end)

      assert_receive {:telemetry_event, [:stacks, :moderation, :classification], %{count: 1},
                      %{outcome: :not_a_book}}
    end

    test "emits :ambiguous when the classification is ambiguous (sad)" do
      attach_telemetry([[:stacks, :moderation, :classification]])

      with_vision(ambiguous(), fn ->
        assert {:error, :not_a_book} = Moderation.run_pipeline(%{image_b64: @test_image_b64})
      end)

      assert_receive {:telemetry_event, [:stacks, :moderation, :classification], %{count: 1},
                      %{outcome: :ambiguous}}
    end
  end

  # ── Step 2: ISBN resolution outcome ────────────────────────────────────

  describe "ISBN resolution telemetry" do
    test "emits :resolved when a candidate resolves to a book (happy)" do
      attach_telemetry([[:stacks, :moderation, :isbn_resolution]])

      context = %{image_b64: @test_image_b64, book_attrs: %{"title" => "The Great Gatsby"}}
      assert {:ok, %{resolved: [_book]}} = Moderation.run_pipeline(context)

      assert_receive {:telemetry_event, [:stacks, :moderation, :isbn_resolution], %{count: 1},
                      %{outcome: :resolved}}
    end

    test "emits :isbn_not_found when a candidate cannot be resolved (sad)" do
      attach_telemetry([[:stacks, :moderation, :isbn_resolution]])

      with_vision(no_resolvable(), fn ->
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(%{image_b64: @test_image_b64})
      end)

      assert_receive {:telemetry_event, [:stacks, :moderation, :isbn_resolution], %{count: 1},
                      %{outcome: :isbn_not_found}}
    end
  end

  # ── Age-gate tiering (repointed to the user/owner set path) ────────────
  #
  # The automatic subject→BISAC classifier was removed (Issue #118), so the
  # pipeline no longer emits [:stacks, :moderation, :tiering]. The metric is
  # repointed onto Books.set_visibility_tier/3, which fires it when a PERSON
  # sets the tier. These tests keep the metric covered on both sides.

  describe "tiering telemetry" do
    test "the pipeline no longer emits tiering — books default to public (happy)" do
      attach_telemetry([[:stacks, :moderation, :tiering]])

      context = %{image_b64: @test_image_b64, book_attrs: %{"title" => "A Peaceful Novel"}}
      assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(context)
      assert book.visibility_tier == "public"

      refute_receive {:telemetry_event, [:stacks, :moderation, :tiering], _, _}, 100
    end

    test "Books.set_visibility_tier emits :age_gated with source :user when a user raises the gate" do
      attach_telemetry([[:stacks, :moderation, :tiering]])

      book = insert(:book, visibility_tier: "public")
      assert {:ok, updated} = Books.set_visibility_tier(book, "age_gated", source: :user)
      assert updated.visibility_tier == "age_gated"

      assert_receive {:telemetry_event, [:stacks, :moderation, :tiering], %{count: 1},
                      %{tier: :age_gated, source: :user}}
    end
  end

  # ── Compound-title expansion ───────────────────────────────────────────

  describe "compound expansion telemetry" do
    test "emits a split measurement when a ' OR '-joined title is expanded" do
      attach_telemetry([[:stacks, :moderation, :compound_expansion]])

      with_vision(compound_title_text(), fn ->
        # Neither part resolves (no HTTP responses registered) so the pipeline
        # ends in :isbn_not_found — but the expansion event fires regardless.
        assert {:error, :isbn_not_found} = Moderation.run_pipeline(%{image_b64: @test_image_b64})
      end)

      assert_receive {:telemetry_event, [:stacks, :moderation, :compound_expansion],
                      %{count: 1, parts: 2}, %{}}
    end

    test "does not emit when the title has no ' OR ' separator" do
      attach_telemetry([[:stacks, :moderation, :compound_expansion]])

      context = %{image_b64: @test_image_b64, book_attrs: %{"title" => "The Great Gatsby"}}
      assert {:ok, %{resolved: [_book]}} = Moderation.run_pipeline(context)

      refute_receive {:telemetry_event, [:stacks, :moderation, :compound_expansion], _, _}, 100
    end
  end
end
