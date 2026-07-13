defmodule Stacks.Discovery.Handlers.LocationUpdatedHandlerTest do
  @moduledoc "Tests for the LocationUpdatedHandler event handler."

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.User
  alias Stacks.Discovery.Handlers.LocationUpdatedHandler
  alias Stacks.Workers.GeographicDiscoveryJob

  describe "handle_event/1" do
    test "enqueues GeographicDiscoveryJob using city/country from the user record" do
      # GDPR (Issue #121): the event payload is UUID-only. The handler resolves
      # the user from aggregate_id and reads the *current* location off the
      # user record.
      user = insert(:user, city: "Cape Town", country_code: "ZA")

      assert :ok =
               LocationUpdatedHandler.handle_event(%{
                 event_type: "user.location_updated",
                 aggregate_id: user.id,
                 payload: %{}
               })

      assert_enqueued(
        worker: GeographicDiscoveryJob,
        args: %{city: "Cape Town", country_code: "ZA"}
      )
    end

    test "does not enqueue when the user record has no city" do
      user = insert(:user, city: nil, country_code: "ZA")

      assert :ok =
               LocationUpdatedHandler.handle_event(%{
                 event_type: "user.location_updated",
                 aggregate_id: user.id,
                 payload: %{}
               })

      refute_enqueued(worker: GeographicDiscoveryJob)
    end

    test "does not enqueue when the user record has no country_code" do
      user = insert(:user, city: "Cape Town")
      # country_code has a DB default ("ZA"), so null it explicitly to model a
      # user whose location is incomplete.
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [country_code: nil])

      assert :ok =
               LocationUpdatedHandler.handle_event(%{
                 event_type: "user.location_updated",
                 aggregate_id: user.id,
                 payload: %{}
               })

      refute_enqueued(worker: GeographicDiscoveryJob)
    end

    test "returns :ok without enqueuing when the user no longer exists (erased)" do
      assert :ok =
               LocationUpdatedHandler.handle_event(%{
                 event_type: "user.location_updated",
                 aggregate_id: Ecto.UUID.generate(),
                 payload: %{}
               })

      refute_enqueued(worker: GeographicDiscoveryJob)
    end

    test "ignores unrelated events" do
      assert :ok =
               LocationUpdatedHandler.handle_event(%{
                 event_type: "book.created",
                 aggregate_id: Ecto.UUID.generate()
               })

      refute_enqueued(worker: GeographicDiscoveryJob)
    end
  end
end
