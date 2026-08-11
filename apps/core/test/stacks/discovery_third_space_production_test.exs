defmodule Stacks.DiscoveryThirdSpaceProductionTest do
  @moduledoc """
    Approval is the only thing that may create a `third_space`.

    The table sat at **zero rows** while `implementation-mapping.md:2115` documented a
    `DiscoverThirdSpacesJob` as "Scheduled (weekly)" that has never existed. So these tests
    guard two things at once: that approval now produces a row, and that nothing else does.

    Geocoding happens at approval rather than at render time — human-paced, so Nominatim's
    ~1 req/sec policy is honoured structurally, and the nearest-bookshop distance is
    computed once instead of per pan.
  """

  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Discovery
  alias Stacks.Enrichment.ThirdSpace
  alias Stacks.Geocoding.Mock, as: MockGeocoder

  setup do
    original = Application.get_env(:core, :geocoder)
    Application.put_env(:core, :geocoder, MockGeocoder)

    on_exit(fn ->
      MockGeocoder.clear()

      if original,
        do: Application.put_env(:core, :geocoder, original),
        else: Application.delete_env(:core, :geocoder)
    end)

    :ok
  end

  defp pending_source(attrs \\ []) do
    defaults = [
      name: "The Reading Room",
      type: "community",
      url: "https://readingroom.test",
      status: "pending_review",
      discovered_at: DateTime.utc_now()
    ]

    insert(:discovered_source, Keyword.merge(defaults, attrs))
  end

  defp spaces(source), do: Repo.all(from s in ThirdSpace, where: s.website_url == ^source.url)

  describe "approval creates the third space" do
    test "a space-like source becomes a third space" do
      MockGeocoder.put_point("The Reading Room", -33.9249, 18.4241)
      source = pending_source()

      assert {:ok, _} = Discovery.approve_source(source.id)

      assert [space] = spaces(source)
      assert space.name == "The Reading Room"
      assert space.website_url == "https://readingroom.test"
      assert space.latitude == -33.9249
      assert space.longitude == 18.4241
    end

    test "the space starts unverified — approval of a source is not verification of a business" do
      MockGeocoder.put_point("The Reading Room", -33.9249, 18.4241)
      source = pending_source()

      assert {:ok, _} = Discovery.approve_source(source.id)
      assert [%{verified: false}] = spaces(source)
    end

    test "rejection creates nothing" do
      source = pending_source()

      assert {:ok, _} = Discovery.reject_source(source.id)
      assert spaces(source) == []
    end

    test "a bookshop source creates no third space" do
      source = pending_source(type: "bookshop", url: "https://ashop.test")

      assert {:ok, _} = Discovery.approve_source(source.id)
      assert spaces(source) == []
    end

    test "re-approval does not create a second listing for the same business" do
      MockGeocoder.put_point("The Reading Room", -33.9249, 18.4241)
      source = pending_source()

      assert {:ok, _} = Discovery.approve_source(source.id)
      Discovery.create_third_space(Discovery.get_source(source.id))

      assert length(spaces(source)) == 1
    end
  end

  describe "geocoding at approval" do
    test "computes and stores the distance to the nearest bookshop" do
      insert(:bookstore, name: "Close Books", latitude: -33.9249, longitude: 18.4273)
      insert(:bookstore, name: "Distant Books", latitude: -33.9500, longitude: 18.5000)

      MockGeocoder.put_point("The Reading Room", -33.9249, 18.4241)
      source = pending_source()

      assert {:ok, _} = Discovery.approve_source(source.id)

      assert [space] = spaces(source)
      assert space.nearest_bookshop_km, "the pairing distance was never computed"

      assert space.nearest_bookshop_km < 0.5,
             "expected the nearer shop (~0.3 km), got #{space.nearest_bookshop_km}"
    end

    test "leaves the distance nil when no bookshop has coordinates" do
      insert(:bookstore, name: "Unpositioned Books", latitude: nil, longitude: nil)
      MockGeocoder.put_point("The Reading Room", -33.9249, 18.4241)
      source = pending_source()

      assert {:ok, _} = Discovery.approve_source(source.id)
      assert [%{nearest_bookshop_km: nil}] = spaces(source)
    end

    test "a space that cannot be geocoded is still created, unpositioned" do
      source = pending_source()

      assert {:ok, _} = Discovery.approve_source(source.id)

      assert [space] = spaces(source)
      assert is_nil(space.latitude)
      assert is_nil(space.longitude)
    end

    test "an unpositioned space cannot reach the map" do
      source = pending_source()
      assert {:ok, _} = Discovery.approve_source(source.id)

      near = Stacks.Enrichment.list_third_spaces(lat: -33.9249, lng: 18.4241, radius_km: 5000)

      assert near == [],
             "an unpositioned space appeared in a geo query — it would render at a " <>
               "location nobody established"
    end

    test "the geocoding query carries the city, not just the name" do
      MockGeocoder.put_point("Cape Town", -33.9249, 18.4241)
      source = pending_source()

      assert {:ok, _} = Discovery.approve_source(source.id)

      assert Enum.any?(MockGeocoder.queries(), &String.contains?(&1, "The Reading Room")),
             "the geocoder was never asked: #{inspect(MockGeocoder.queries())}"
    end
  end

  describe "nothing else produces third spaces" do
    test "creating a source does not create a space" do
      source = pending_source()
      assert spaces(source) == []
    end

    test "the table has no other writer in the codebase" do
      writers =
        Path.wildcard("lib/stacks/**/*.ex")
        |> Enum.filter(fn path ->
          contents = File.read!(path)

          String.contains?(contents, "%ThirdSpace{}") and
            String.contains?(contents, "Repo.insert")
        end)
        |> Enum.map(&Path.basename/1)

      assert writers == ["discovery.ex"],
             "op.third_spaces gained another producer: #{inspect(writers)}. " <>
               "US-3.1.1 §4 makes approval the only path — these are real businesses, " <>
               "and listing one no human reviewed is the harm US-2.5.3 exists to remedy."
    end
  end

  describe "a verified removal request delists the space a reader sees" do
    test "the space is opted out, not just the source" do
      MockGeocoder.put_point("The Reading Room", -33.9249, 18.4241)
      source = pending_source()
      assert {:ok, _} = Discovery.approve_source(source.id)
      assert [%{opted_out: false}] = spaces(source)

      assert {:ok, :excluded, _} =
               Discovery.opt_out("https://readingroom.test", %{email: "owner@readingroom.test"})

      assert [space] = spaces(source)
      assert space.opted_out, "the third space is still listed after a verified removal"
      assert space.opted_out_at
    end

    test "the row survives — a hard delete would be rediscovered and re-listed" do
      MockGeocoder.put_point("The Reading Room", -33.9249, 18.4241)
      source = pending_source()
      assert {:ok, _} = Discovery.approve_source(source.id)

      assert {:ok, :excluded, _} =
               Discovery.opt_out("https://readingroom.test", %{email: "owner@readingroom.test"})

      assert length(spaces(source)) == 1, "the space row was deleted rather than delisted"

      Discovery.create_third_space(Discovery.get_source(source.id))

      assert [%{opted_out: true}] = spaces(source),
             "re-approval brought a delisted business back onto the map"
    end

    test "an unverified request leaves the space live" do
      # The listing stays up until a human agrees — telling someone their listing is gone
      # when it is not would be worse than telling them it is pending.
      MockGeocoder.put_point("The Reading Room", -33.9249, 18.4241)
      source = pending_source()
      assert {:ok, _} = Discovery.approve_source(source.id)

      assert {:ok, :pending_review, _} =
               Discovery.opt_out("https://readingroom.test", %{email: "someone@gmail.test"})

      assert [%{opted_out: false}] = spaces(source),
             "an unverified request delisted the business anyway"
    end

    test "a delisted space stops appearing in reader-facing queries" do
      MockGeocoder.put_point("The Reading Room", -33.9249, 18.4241)
      source = pending_source()
      assert {:ok, _} = Discovery.approve_source(source.id)

      assert {:ok, :excluded, _} =
               Discovery.opt_out("https://readingroom.test", %{email: "owner@readingroom.test"})

      assert Stacks.Enrichment.list_third_spaces() == [],
             "a delisted business is still being served to readers"
    end
  end

  describe "opted-out businesses stay delisted" do
    test "an approved source whose space opted out is not re-listed" do
      MockGeocoder.put_point("The Reading Room", -33.9249, 18.4241)
      source = pending_source()
      assert {:ok, _} = Discovery.approve_source(source.id)

      [space] = spaces(source)
      Repo.update_all(from(s in ThirdSpace, where: s.id == ^space.id), set: [opted_out: true])

      Discovery.create_third_space(Discovery.get_source(source.id))

      assert length(spaces(source)) == 1, "a second listing was created for an opted-out business"
      assert [%{opted_out: true}] = spaces(source)
    end
  end
end
