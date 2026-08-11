defmodule Stacks.ModerationTelemetryTest do
  @moduledoc """
  Firing tests for the 228 moderation-funnel counters: classification
  outcome (:book/:not_a_book/:ambiguous), ISBN resolution
  (:resolved/:isbn_not_found), age-gate tiering (:public/:age_gated),
  and compound-title expansion. Metadata tags are whitelisted atoms —
  Prometheus label cardinality depends on it.
  """

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

  defp compound_title_text do
    book_response([book_candidate(title: "First Book OR Second Book", confidence: 0.9)])
  end

  defp no_resolvable, do: book_response([book_candidate()])

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

  describe "compound expansion telemetry" do
    test "emits a split measurement when a ' OR '-joined title is expanded" do
      attach_telemetry([[:stacks, :moderation, :compound_expansion]])

      with_vision(compound_title_text(), fn ->
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
