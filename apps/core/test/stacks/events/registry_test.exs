defmodule Stacks.Events.RegistryTest do
  use ExUnit.Case, async: true

  alias Stacks.Events.Registry

  describe "handlers_for/1" do
    test "returns empty list for unregistered event type" do
      assert Registry.handlers_for("nonexistent.event") == []
    end

    test "returns empty list for empty string" do
      assert Registry.handlers_for("") == []
    end
  end

  describe "all_event_types/0" do
    test "returns a list" do
      assert is_list(Registry.all_event_types())
    end

    test "all entries are strings" do
      assert Enum.all?(Registry.all_event_types(), &is_binary/1)
    end
  end
end
