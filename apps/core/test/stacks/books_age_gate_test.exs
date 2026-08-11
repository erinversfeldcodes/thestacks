defmodule Stacks.BooksAgeGateTest do
  @moduledoc """
  Tests for `Stacks.Books.set_visibility_tier/3` — the user/owner-set age-gate
  model that replaced the removed automatic subject→BISAC classifier (#118).

  A book is age-gated because a PERSON marked it, not because code guessed.
  The user path is raise-only (public → age_gated); only the owner may un-gate.
  """

  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Books

  defp attach_tiering do
    test_pid = self()
    handler_id = "test-tiering-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:stacks, :moderation, :tiering],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "set_visibility_tier/3 — user path (raise_only)" do
    test "a user marking a public book adults_only raises it to age_gated + fires telemetry" do
      attach_tiering()
      book = insert(:book, visibility_tier: "public")

      assert {:ok, updated} = Books.set_visibility_tier(book, "age_gated", source: :user)
      assert updated.visibility_tier == "age_gated"

      assert_receive {:telemetry_event, [:stacks, :moderation, :tiering], %{count: 1},
                      %{tier: :age_gated, source: :user}}
    end

    test "a user attempting to LOWER (age_gated → public) is forbidden and leaves the tier unchanged" do
      book = insert(:book, visibility_tier: "age_gated")

      assert {:error, :forbidden} = Books.set_visibility_tier(book, "public", source: :user)
      assert Core.Repo.reload!(book).visibility_tier == "age_gated"
    end

    test "raising an already-age_gated book is a silent no-op (no telemetry)" do
      attach_tiering()
      book = insert(:book, visibility_tier: "age_gated")

      assert {:ok, ^book} = Books.set_visibility_tier(book, "age_gated", source: :user)
      refute_receive {:telemetry_event, [:stacks, :moderation, :tiering], _, _}, 100
    end

    test "accepts a book id, and returns {:error, :not_found} for a missing book" do
      book = insert(:book, visibility_tier: "public")

      assert {:ok, updated} = Books.set_visibility_tier(book.id, "age_gated", source: :user)
      assert updated.visibility_tier == "age_gated"

      assert {:error, :not_found} =
               Books.set_visibility_tier(Ecto.UUID.generate(), "age_gated", source: :user)
    end
  end

  describe "set_visibility_tier/3 — owner path (raise_only: false)" do
    test "the owner can LOWER (age_gated → public) and it fires telemetry with source :owner" do
      attach_tiering()
      book = insert(:book, visibility_tier: "age_gated")

      assert {:ok, updated} =
               Books.set_visibility_tier(book, "public", source: :owner, raise_only: false)

      assert updated.visibility_tier == "public"

      assert_receive {:telemetry_event, [:stacks, :moderation, :tiering], %{count: 1},
                      %{tier: :public, source: :owner}}
    end

    test "the owner can also RAISE (public → age_gated)" do
      book = insert(:book, visibility_tier: "public")

      assert {:ok, updated} =
               Books.set_visibility_tier(book, "age_gated", source: :owner, raise_only: false)

      assert updated.visibility_tier == "age_gated"
    end
  end
end
