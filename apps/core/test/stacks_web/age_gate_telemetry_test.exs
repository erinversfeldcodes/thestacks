defmodule StacksWeb.AgeGateTelemetryTest do
  @moduledoc """
  Firing tests for the age-gate operational counters added in Issue #228
  (US-4.2 §13, epic #118).

  Covers:
  - `AgeGate.enforce/2` — `:blocked` (403) vs `:passed` outcome, emitted
    ONLY for age-gated books (never the passthrough clause).
  - `Stacks.AgeVerification.record_verification/3` — `:success` outcome
    (repointed from the removed self-declared settings endpoint, ADR-020).

  Metadata tags are whitelisted atoms only — no email, user id, or other
  PII (GDPR: telemetry is a warehouse-adjacent sink).
  """

  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.AgeVerification
  alias StacksWeb.Plugs.AgeGate

  @age_gated_book %{visibility_tier: "age_gated"}
  @public_book %{visibility_tier: "public"}

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = "test-agegate-tel-#{System.unique_integer([:positive])}"

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

  # ── AgeGate.enforce/2 ──────────────────────────────────────────────────

  describe "age-gate enforcement telemetry" do
    test "emits :passed when an age-verified user accesses an age-gated book (happy)", %{
      conn: conn
    } do
      attach_telemetry([[:stacks, :age_gate, :enforce]])
      user = insert(:user, age_verified: true)
      conn = Guardian.Plug.put_current_resource(conn, user)

      result = AgeGate.enforce(conn, @age_gated_book)
      refute result.halted

      assert_receive {:telemetry_event, [:stacks, :age_gate, :enforce], %{count: 1},
                      %{outcome: :passed}}
    end

    test "emits :blocked when an unverified user accesses an age-gated book (sad)", %{conn: conn} do
      attach_telemetry([[:stacks, :age_gate, :enforce]])

      result = AgeGate.enforce(conn, @age_gated_book)
      assert result.halted
      assert result.status == 403

      assert_receive {:telemetry_event, [:stacks, :age_gate, :enforce], %{count: 1},
                      %{outcome: :blocked}}
    end

    test "does NOT emit for a non-age-gated (public) book", %{conn: conn} do
      attach_telemetry([[:stacks, :age_gate, :enforce]])

      result = AgeGate.enforce(conn, @public_book)
      refute result.halted

      refute_receive {:telemetry_event, [:stacks, :age_gate, :enforce], _, _}, 100
    end

    test "does NOT emit for a nil book", %{conn: conn} do
      attach_telemetry([[:stacks, :age_gate, :enforce]])

      result = AgeGate.enforce(conn, nil)
      refute result.halted

      refute_receive {:telemetry_event, [:stacks, :age_gate, :enforce], _, _}, 100
    end
  end

  # ── AgeVerification.record_verification/3 (ADR-020) ─────────────────────

  describe "age-verification telemetry" do
    test "emits :success when a provider verification is recorded (happy)" do
      attach_telemetry([[:stacks, :age_verification]])
      user = insert(:user, age_verified: false)

      assert {:ok, verified} = AgeVerification.record_verification(user, "test", nil)
      assert verified.age_verified == true

      assert_receive {:telemetry_event, [:stacks, :age_verification], %{count: 1},
                      %{outcome: :success}}
    end

    test "emits :success (repointed family) — never the removed :invalid outcome" do
      attach_telemetry([[:stacks, :age_verification]])
      user = insert(:user, age_verified: false)

      assert {:ok, _} = AgeVerification.record_verification(user, "test", nil)

      assert_receive {:telemetry_event, [:stacks, :age_verification], %{count: 1},
                      %{outcome: :success}}

      refute_receive {:telemetry_event, [:stacks, :age_verification], _, %{outcome: :invalid}},
                     100
    end
  end
end
