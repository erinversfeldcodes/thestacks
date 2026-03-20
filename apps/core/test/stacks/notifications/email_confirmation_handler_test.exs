defmodule Stacks.Notifications.EmailConfirmationHandlerTest do
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Notifications.EmailConfirmationHandler

  describe "handle_event/1" do
    test "enqueues EmailDeliveryJob when confirmation is required" do
      user = insert(:user, email_confirmed: false)

      Application.put_env(:core, :require_email_confirmation, true)

      on_exit(fn ->
        Application.put_env(:core, :require_email_confirmation, false)
      end)

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

    test "does not enqueue when confirmation is not required" do
      user = insert(:user)

      # flag is false by default in test.exs
      assert :ok =
               EmailConfirmationHandler.handle_event(%{
                 event_type: "user.registered",
                 aggregate_id: user.id,
                 payload: %{role: "user"}
               })

      refute_enqueued(worker: Stacks.Workers.EmailDeliveryJob)
    end

    test "handles unknown event types gracefully" do
      assert :ok =
               EmailConfirmationHandler.handle_event(%{
                 event_type: "some.other.event",
                 aggregate_id: Ecto.UUID.generate()
               })
    end

    test "returns ok when user not found and confirmation is required" do
      non_existent_id = Ecto.UUID.generate()

      Application.put_env(:core, :require_email_confirmation, true)

      on_exit(fn ->
        Application.put_env(:core, :require_email_confirmation, false)
      end)

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
