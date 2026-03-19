defmodule Stacks.Social.UsersNotificationColumnsTest do
  use Core.DataCase, async: true

  import Stacks.Factory
  import Ecto.Query

  describe "users notification preference columns" do
    test "all notification columns default to expected values after user insert" do
      user = insert(:user)

      result =
        Core.Repo.one(
          from(u in "users",
            prefix: "op",
            where: u.id == type(^user.id, :binary_id),
            select: %{
              notify_marketplace: u.notify_marketplace,
              notify_group_invitations: u.notify_group_invitations,
              notify_wishlist_availability: u.notify_wishlist_availability,
              notify_event_matches: u.notify_event_matches,
              onboarding_completed: u.onboarding_completed
            }
          )
        )

      assert result.notify_marketplace == true
      assert result.notify_group_invitations == true
      assert result.notify_wishlist_availability == false
      assert result.notify_event_matches == false
      assert result.onboarding_completed == false
    end
  end
end
