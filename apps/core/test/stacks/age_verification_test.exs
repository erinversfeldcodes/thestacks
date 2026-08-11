defmodule Stacks.AgeVerificationTest do
  @moduledoc """
    Tests for the provider-sourced age-verification recorder (ADR-020) — the sole
    writer of the age_verified / age_verified_at / age_verification_provider fields.
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts
  alias Stacks.AgeVerification

  describe "record_verification/3" do
    test "sets all three fields and returns {:ok, user}" do
      user = insert(:user, age_verified: false)
      at = ~U[2026-07-16 10:00:00.000000Z]

      assert {:ok, updated} = AgeVerification.record_verification(user, "yoti", at)

      assert updated.age_verified == true
      assert updated.age_verified_at == at
      assert updated.age_verification_provider == "yoti"

      reloaded = Accounts.get_user!(user.id)
      assert reloaded.age_verified == true
      assert reloaded.age_verification_provider == "yoti"
    end

    test "defaults age_verified_at to now when nil" do
      user = insert(:user, age_verified: false)
      before = DateTime.utc_now()

      assert {:ok, updated} = AgeVerification.record_verification(user, "smile_id", nil)

      assert updated.age_verified == true
      assert DateTime.compare(updated.age_verified_at, before) in [:eq, :gt]
    end

    test "emits [:stacks, :age_verification] with outcome :success" do
      handler_id = "av-success-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:stacks, :age_verification],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      user = insert(:user, age_verified: false)
      assert {:ok, _} = AgeVerification.record_verification(user, "sumsub", nil)

      assert_receive {:telemetry, [:stacks, :age_verification], %{count: 1}, %{outcome: :success}}
    end
  end

  describe "revoke/1" do
    test "clears verification and returns {:ok, user}" do
      user =
        insert(:user,
          age_verified: true,
          age_verified_at: DateTime.utc_now(),
          age_verification_provider: "yoti"
        )

      assert {:ok, updated} = AgeVerification.revoke(user)

      assert updated.age_verified == false
      assert updated.age_verified_at == nil
      assert updated.age_verification_provider == nil
    end
  end
end
