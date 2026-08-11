defmodule Stacks.Notifications.EmailConfirmationHandlerTest do
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Notifications.EmailConfirmationHandler

  describe "handle_event/1" do
    test "enqueues EmailDeliveryJob on user.registered" do
      user = insert(:user, email_confirmed: false)
      token = Phoenix.Token.sign(CoreWeb.Endpoint, "email_confirm", user.id)

      {:ok, user} =
        user |> Ecto.Changeset.change(%{email_confirmation_token: token}) |> Core.Repo.update()

      assert :ok =
               EmailConfirmationHandler.handle_event(%{
                 event_type: "user.registered",
                 aggregate_id: user.id,
                 payload: %{role: "user"}
               })

      assert_enqueued(
        worker: Stacks.Workers.EmailDeliveryJob,
        args: %{"template" => "registration_confirmation", "user_id" => user.id}
      )
    end

    test "handles unknown event types gracefully" do
      assert :ok =
               EmailConfirmationHandler.handle_event(%{
                 event_type: "some.other.event",
                 aggregate_id: Ecto.UUID.generate()
               })
    end

    test "no-ops (ok, nothing enqueued) when the user is already confirmed" do
      user = insert(:user, email_confirmed: true, email_confirmation_token: nil)

      assert :ok =
               EmailConfirmationHandler.handle_event(%{
                 event_type: "user.registered",
                 aggregate_id: user.id,
                 payload: %{role: "user"}
               })

      refute_enqueued(worker: Stacks.Workers.EmailDeliveryJob)
    end

    test "returns ok when user not found" do
      non_existent_id = Ecto.UUID.generate()

      assert :ok =
               EmailConfirmationHandler.handle_event(%{
                 event_type: "user.registered",
                 aggregate_id: non_existent_id,
                 payload: %{role: "user"}
               })

      refute_enqueued(worker: Stacks.Workers.EmailDeliveryJob)
    end
  end
end
