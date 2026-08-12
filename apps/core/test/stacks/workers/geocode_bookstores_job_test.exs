defmodule Stacks.Workers.GeocodeBookstoresJobTest do
  @moduledoc """
      Guards the bookshop geocoding backfill, and specifically its **throttle**.

      This job is the batch entry point whose *absence* `Stacks.Geocoding.Nominatim` previously
      cited as the structural guarantee that Nominatim's ~1 req/sec usage policy was honoured.
      Adding it means the guarantee has to be asserted instead of assumed — otherwise the policy
      is protected by a comment.

      The tests override the delay to 0 so the suite stays usable, and assert the **documented
      default** separately. That way lowering the real throttle is a visible, test-breaking act
      rather than a silent one.
  """

  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Enrichment.Bookstore
  alias Stacks.Geocoding.Mock, as: MockGeocoder
  alias Stacks.Workers.GeocodeBookstoresJob

  setup do
    original_geocoder = Application.get_env(:core, :geocoder)
    original_throttle = Application.get_env(:core, :geocode_throttle_ms)

    Application.put_env(:core, :geocoder, MockGeocoder)
    Application.put_env(:core, :geocode_throttle_ms, 0)

    on_exit(fn ->
      MockGeocoder.clear()

      if original_geocoder,
        do: Application.put_env(:core, :geocoder, original_geocoder),
        else: Application.delete_env(:core, :geocoder)

      if original_throttle,
        do: Application.put_env(:core, :geocode_throttle_ms, original_throttle),
        else: Application.delete_env(:core, :geocode_throttle_ms)
    end)

    :ok
  end

  defp reload(store), do: Repo.get!(Bookstore, store.id)

  describe "the throttle" do
    test "the documented default stays above Nominatim's ~1 req/sec policy" do
      assert GeocodeBookstoresJob.default_throttle_ms() >= 1_000,
             "the default throttle dropped below 1 req/sec, which breaches Nominatim's " <>
               "usage policy and risks the project's IP being blocked"
    end

    test "one run is capped" do
      assert GeocodeBookstoresJob.batch_size() <= 50

      for i <- 1..30 do
        insert(:bookstore, name: "Shop #{i}", latitude: nil, longitude: nil, has_physical: true)
      end

      assert length(GeocodeBookstoresJob.ungeocoded_stores()) <= GeocodeBookstoresJob.batch_size()
    end

    test "requests are made one per bookshop, serially" do
      for name <- ["Alpha Books", "Beta Books", "Gamma Books"] do
        insert(:bookstore, name: name, latitude: nil, longitude: nil, has_physical: true)
      end

      assert :ok = perform_job(GeocodeBookstoresJob, %{})

      assert length(MockGeocoder.queries()) == 3,
             "expected one request per bookshop, got #{inspect(MockGeocoder.queries())}"
    end
  end

  describe "which bookshops get geocoded" do
    test "positions a physical shop that has no coordinates" do
      MockGeocoder.put_point("The Book Lounge", -33.9269, 18.4187)
      store = insert(:bookstore, name: "The Book Lounge", latitude: nil, longitude: nil)

      assert :ok = perform_job(GeocodeBookstoresJob, %{})

      positioned = reload(store)
      assert positioned.latitude == -33.9269
      assert positioned.longitude == 18.4187
    end

    test "skips an online-only shop — a website is not a place" do
      MockGeocoder.put_point("Loot", -26.2, 28.0)
      store = insert(:bookstore, name: "Loot", has_physical: false, latitude: nil, longitude: nil)

      assert :ok = perform_job(GeocodeBookstoresJob, %{})

      assert is_nil(reload(store).latitude)

      refute Enum.any?(MockGeocoder.queries(), &String.contains?(&1, "Loot")),
             "an online-only shop was sent to the geocoder"
    end

    test "never overwrites coordinates that already exist" do
      MockGeocoder.put_point("Already Placed", 1.0, 2.0)

      store =
        insert(:bookstore, name: "Already Placed", latitude: -33.9, longitude: 18.4)

      assert :ok = perform_job(GeocodeBookstoresJob, %{})

      unchanged = reload(store)
      assert unchanged.latitude == -33.9
      assert unchanged.longitude == 18.4

      refute Enum.any?(MockGeocoder.queries(), &String.contains?(&1, "Already Placed")),
             "an already-positioned shop was re-geocoded"
    end

    test "a shop the geocoder cannot place is left unpositioned, not guessed" do
      store = insert(:bookstore, name: "Nowhere Books", latitude: nil, longitude: nil)

      assert :ok = perform_job(GeocodeBookstoresJob, %{})
      assert is_nil(reload(store).latitude)
    end

    test "one failure does not abandon the rest of the batch" do
      MockGeocoder.put_point("Findable Books", -33.9, 18.4)
      unfindable = insert(:bookstore, name: "Unfindable Books", latitude: nil, longitude: nil)
      findable = insert(:bookstore, name: "Findable Books", latitude: nil, longitude: nil)

      assert :ok = perform_job(GeocodeBookstoresJob, %{})

      assert reload(findable).latitude == -33.9
      assert is_nil(reload(unfindable).latitude)
    end

    test "is idempotent — a second run has nothing left to do" do
      MockGeocoder.put_point("Repeat Books", -33.9, 18.4)
      insert(:bookstore, name: "Repeat Books", latitude: nil, longitude: nil)

      assert :ok = perform_job(GeocodeBookstoresJob, %{})
      first_pass = length(MockGeocoder.queries())

      assert :ok = perform_job(GeocodeBookstoresJob, %{})

      assert length(MockGeocoder.queries()) == first_pass,
             "the second run re-geocoded shops that were already positioned"
    end
  end

  describe "the pairing rule it unblocks" do
    test "a geocoded bookshop makes nearest_bookshop_km computable" do
      MockGeocoder.put_point("Corner Books", -33.9249, 18.4273)
      insert(:bookstore, name: "Corner Books", latitude: nil, longitude: nil)

      assert :ok = perform_job(GeocodeBookstoresJob, %{})

      source =
        insert(:discovered_source,
          name: "The Reading Room",
          type: "community",
          url: "https://readingroom.test",
          status: "pending_review",
          discovered_at: DateTime.utc_now()
        )

      MockGeocoder.put_point("The Reading Room", -33.9249, 18.4241)
      assert {:ok, _} = Stacks.Discovery.approve_source(source.id)

      [space] = Repo.all(Stacks.Enrichment.ThirdSpace)

      assert space.nearest_bookshop_km,
             "the pairing distance is still nil — the bookshop coordinates did not land"

      assert space.nearest_bookshop_km < 0.5,
             "expected the space to be within 500 m of the geocoded shop, " <>
               "got #{space.nearest_bookshop_km} km"

      assert [_] = Stacks.Enrichment.list_third_spaces(near_bookshop_km: 0.5)
    end
  end
end
