defmodule Stacks.AgeGatingFlagOffTest do
  @moduledoc """
  Shipped-dark behaviour (ADR-020): with `:age_gating_enabled` OFF, all three
  enforcement points are no-ops — age-gated content behaves exactly like public.

  The test env defaults the flag ON (so the enforcement suite keeps exercising
  the gate); these tests temporarily flip it OFF and restore it. `async: false`
  because the flag is a process-global Application env value.

  The flag-ON counterparts live in `StacksWeb.Plugs.AgeGateTest`,
  `Stacks.VisibilityTest`, and `StacksWeb.CatalogueControllerTest`.
  """

  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Books
  alias Stacks.Visibility
  alias StacksWeb.Plugs.AgeGate

  @age_gated_book %{visibility_tier: "age_gated"}

  setup do
    original = Application.get_env(:core, :age_gating_enabled)
    Application.put_env(:core, :age_gating_enabled, false)
    on_exit(fn -> Application.put_env(:core, :age_gating_enabled, original) end)
    :ok
  end

  test "(a) AgeGate.enforce does NOT 403 an unverified user on an age-gated book", %{conn: conn} do
    result = AgeGate.enforce(conn, @age_gated_book)

    refute result.halted
    assert result.status == nil
  end

  test "(a') AgeGate.enforce emits NO enforce telemetry when the flag is off", %{conn: conn} do
    handler_id = "flagoff-enforce-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:stacks, :age_gate, :enforce],
      fn event, m, meta, _ -> send(test_pid, {:telemetry, event, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    refute AgeGate.enforce(conn, @age_gated_book).halted
    refute_receive {:telemetry, [:stacks, :age_gate, :enforce], _, _}, 100
  end

  test "(b) list_catalogue INCLUDES age-gated books for an unverified viewer" do
    book = insert(:book, title: "Dark Matter", visibility_tier: "age_gated")

    unverified = insert(:user, age_verified: false)
    viewer = {:platform_user, unverified.id, false}

    {books, total} = Books.list_catalogue(viewer: viewer)

    assert total >= 1
    assert Enum.any?(books, &(&1.id == book.id))
  end

  test "(c) Visibility.check_age_gate returns :visible for an age-gated book + unverified viewer" do
    book = insert(:book, visibility_tier: "age_gated")
    viewer = insert(:user, age_verified: false)

    assert :visible = Visibility.resolve_visibility(book, {:platform_user, viewer.id})
  end
end
