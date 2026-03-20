defmodule Stacks.GDPR.ImageRetentionTest do
  @moduledoc """
  Tests for Stacks.GDPR.ImageRetention.

  Verifies that expired/stuck images are deleted and that an `image.expired`
  event is emitted for each deleted record.
  """

  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.GDPR.ImageRetention

  defp event_count(event_type) do
    Repo.aggregate(
      from(e in "event_log", prefix: "op", where: e.event_type == ^event_type),
      :count
    )
  end

  describe "cleanup_expired_images/0" do
    test "deletes images past their expires_at" do
      _expired =
        insert(:uploaded_image,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day),
          uploaded_at: DateTime.add(DateTime.utc_now(), -31, :day)
        )

      assert {:ok, 1} = ImageRetention.cleanup_expired_images()
    end

    test "does not delete images not yet expired" do
      _fresh = insert(:uploaded_image, expires_at: DateTime.add(DateTime.utc_now(), 29, :day))

      assert {:ok, 0} = ImageRetention.cleanup_expired_images()
    end

    test "emits image.expired event for each deleted record" do
      _expired1 =
        insert(:uploaded_image,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day),
          uploaded_at: DateTime.add(DateTime.utc_now(), -31, :day)
        )

      _expired2 =
        insert(:uploaded_image,
          expires_at: DateTime.add(DateTime.utc_now(), -2, :day),
          uploaded_at: DateTime.add(DateTime.utc_now(), -32, :day)
        )

      before_count = event_count("image.expired")

      ImageRetention.cleanup_expired_images()

      assert event_count("image.expired") == before_count + 2
    end

    test "returns {:ok, 0} and emits no events when nothing is expired" do
      before_count = event_count("image.expired")

      assert {:ok, 0} = ImageRetention.cleanup_expired_images()

      assert event_count("image.expired") == before_count
    end
  end

  describe "cleanup_stuck_images/0" do
    test "deletes pending images stuck for more than 2 hours" do
      _stuck =
        insert(:uploaded_image,
          status: "pending",
          uploaded_at: DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
        )

      assert {:ok, 1} = ImageRetention.cleanup_stuck_images()
    end

    test "does not delete pending images uploaded recently" do
      _recent =
        insert(:uploaded_image,
          status: "pending",
          uploaded_at: DateTime.add(DateTime.utc_now(), -30 * 60, :second)
        )

      assert {:ok, 0} = ImageRetention.cleanup_stuck_images()
    end

    test "does not delete non-pending images regardless of age" do
      _resolved =
        insert(:uploaded_image,
          status: "resolved",
          uploaded_at: DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
        )

      assert {:ok, 0} = ImageRetention.cleanup_stuck_images()
    end

    test "emits image.expired event for each stuck image deleted" do
      _stuck =
        insert(:uploaded_image,
          status: "pending",
          uploaded_at: DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
        )

      before_count = event_count("image.expired")

      ImageRetention.cleanup_stuck_images()

      assert event_count("image.expired") == before_count + 1
    end
  end
end
