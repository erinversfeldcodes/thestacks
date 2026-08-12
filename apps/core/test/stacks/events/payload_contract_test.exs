defmodule Stacks.Events.PayloadContractTest do
  @moduledoc """
      The three static guards over the event-payload contract (the schema `buf` can't
      see, because payloads are opaque `google.protobuf.Struct`). Shape-drift itself is
      caught at emit time by `Stacks.Events.emit/1` (the whole suite drives the
      emitters); this file enforces the parts a runtime emit can't:

        * PII-lint — no personal/free-text key sneaks into a payload unjustified.
        * version ↔ upcaster — every bumped version has a migration.
        * coverage — every emitted event type is declared.
  """
  use ExUnit.Case, async: true

  alias Stacks.Events.{PayloadContract, Upcaster}

  @contract PayloadContract.contract()

  defp identifier?(key), do: String.ends_with?(key, "_id") or String.ends_with?(key, "_ids")

  defp personal_shaped?(key) do
    not identifier?(key) and Enum.any?(PayloadContract.pii_shaped(), &String.contains?(key, &1))
  end

  describe "PII-lint (would have caught the blog-title leak)" do
    test "every payload key is an identifier, non-personal-shaped, or allowlisted with a reason" do
      allowlist = PayloadContract.free_text_allowlist()

      violations =
        for {type, %{keys: keys} = entry} <- @contract,
            key <- keys ++ Map.get(entry, :optional, []),
            personal_shaped?(key),
            not Map.has_key?(allowlist, key),
            do: "#{type} → #{key}"

      assert violations == [],
             "personal/free-text-shaped payload keys with no justification — drop them to a UUID, or " <>
               "add to PayloadContract.free_text_allowlist/0 with a reason (see completion-bar §PII): " <>
               inspect(violations)
    end

    test "every allowlist entry carries a non-empty justification" do
      for {key, reason} <- PayloadContract.free_text_allowlist() do
        assert is_binary(reason) and String.length(reason) > 5,
               "allowlist #{key} needs a real reason"
      end
    end
  end

  describe "version ↔ upcaster" do
    test "every event type with version > 1 has an Upcaster migrating each older version forward" do
      for {type, %{version: version}} <- @contract, version > 1, old <- 1..(version - 1) do
        upcast =
          Upcaster.upcast(%{event_type: type, schema_version: old, payload: %{}})

        assert upcast.schema_version == version,
               "#{type} is at v#{version} but Upcaster does not migrate v#{old} → v#{version}. " <>
                 "Add an Upcaster clause (see Stacks.Events.Upcaster)."
      end
    end
  end

  describe "coverage" do
    test "every literal event_type emitted in lib/ is declared in the contract" do
      emit_re = ~r/emit(?:_safe)?\(%\{[^}]*?event_type:\s*"([a-z0-9_.]+)"/s

      emitted =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.flat_map(fn f ->
          Regex.scan(emit_re, File.read!(f), capture: :all_but_first)
        end)
        |> List.flatten()
        |> Enum.uniq()

      undeclared = Enum.reject(emitted, &Map.has_key?(@contract, &1))

      assert undeclared == [],
             "these emitted event types have no PayloadContract entry (add one, with version + keys): " <>
               inspect(undeclared)
    end
  end

  describe "validate!/1 (the emit-time guard) bites" do
    test "raises when a payload gains an undeclared key" do
      assert_raise PayloadContract.Violation, ~r/payload keys/, fn ->
        PayloadContract.validate!(%{
          event_type: "user.registered",
          schema_version: 1,
          payload: %{"role" => "user", "email" => "leak@example.com"}
        })
      end
    end

    test "raises when schema_version does not match the contract" do
      assert_raise PayloadContract.Violation, ~r/schema_version/, fn ->
        PayloadContract.validate!(%{
          event_type: "blog.post_created",
          schema_version: 1,
          payload: %{"user_id" => "u-1", "visibility" => "platform"}
        })
      end
    end

    test "accepts a payload with or without a declared-optional key" do
      assert :ok =
               PayloadContract.validate!(%{
                 event_type: "image.rejected",
                 payload: %{"reason" => "not_a_book"}
               })

      assert :ok =
               PayloadContract.validate!(%{
                 event_type: "image.rejected",
                 payload: %{"reason" => "isbn_mismatch", "isbn" => "9780000000000"}
               })
    end

    test "raises when a required key is missing" do
      assert_raise PayloadContract.Violation, ~r/missing required/, fn ->
        PayloadContract.validate!(%{
          event_type: "image.rejected",
          payload: %{"isbn" => "9780000000000"}
        })
      end
    end

    test "passes a correct payload, and ignores unknown (uncontracted) event types" do
      assert :ok =
               PayloadContract.validate!(%{
                 event_type: "blog.post_created",
                 schema_version: 2,
                 payload: %{"user_id" => "u-1", "visibility" => "platform"}
               })

      assert :ok =
               PayloadContract.validate!(%{event_type: "not.in.contract", payload: %{"x" => 1}})
    end
  end
end
