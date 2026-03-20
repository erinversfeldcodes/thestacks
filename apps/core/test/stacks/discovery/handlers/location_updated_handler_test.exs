defmodule Stacks.Discovery.Handlers.LocationUpdatedHandlerTest do
  @moduledoc "Tests for the LocationUpdatedHandler event handler."

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  alias Stacks.Discovery.Handlers.LocationUpdatedHandler
  alias Stacks.Workers.GeographicDiscoveryJob

  describe "handle_event/1" do
    test "enqueues GeographicDiscoveryJob for atom-keyed payload" do
      assert :ok =
               LocationUpdatedHandler.handle_event(%{
                 event_type: "user.location_updated",
                 payload: %{city: "Cape Town", country_code: "ZA"}
               })

      assert_enqueued(
        worker: GeographicDiscoveryJob,
        args: %{city: "Cape Town", country_code: "ZA"}
      )
    end

    test "enqueues GeographicDiscoveryJob for string-keyed payload" do
      assert :ok =
               LocationUpdatedHandler.handle_event(%{
                 event_type: "user.location_updated",
                 payload: %{"city" => "London", "country_code" => "GB"}
               })

      assert_enqueued(
        worker: GeographicDiscoveryJob,
        args: %{city: "London", country_code: "GB"}
      )
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
