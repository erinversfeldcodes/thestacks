defmodule Stacks.GeocodingTest do
  @moduledoc """
    Tests the geocoding seam and Nominatim's response handling.

    The adapter's *request* half is a single Finch call with no branching, so it is not
    mocked — that would test Finch. Everything with a decision in it lives in `handle/2`,
    which is exercised directly against constructed responses: no network, no stub server,
    and the 429 path is reachable, which it would not be against a live service.
  """

  use ExUnit.Case, async: false

  alias Stacks.Geocoding
  alias Stacks.Geocoding.Mock, as: MockGeocoder
  alias Stacks.Geocoding.Nominatim

  describe "query_for/1" do
    test "joins the parts a geocoder needs into one place description" do
      assert Geocoding.query_for(%{
               name: "The Book Lounge",
               city: "Cape Town",
               country_code: "ZA"
             }) ==
               "The Book Lounge, Cape Town, ZA"
    end

    test "drops missing parts instead of rendering empty ones" do
      assert Geocoding.query_for(%{name: "Cafe", city: nil, country_code: "ZA"}) == "Cafe, ZA"
      assert Geocoding.query_for(%{name: "Cafe", city: "", country_code: nil}) == "Cafe"
    end
  end

  describe "the test environment's provider floor" do
    test "no test can reach the live geocoder by omission" do
      provider = Application.get_env(:core, :geocoder)

      refute provider in [nil, Nominatim],
             "the :test geocoder is #{inspect(provider)} — tests would hit the live " <>
               "Nominatim service. See apps/core/config/test.exs."
    end
  end

  describe "geocode/1 — the provider seam" do
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

    test "delegates to the configured provider" do
      MockGeocoder.put_point("Somewhere", 1.5, 2.5)

      assert {:ok, %{latitude: 1.5, longitude: 2.5}} = Geocoding.geocode("Somewhere")
    end

    test "refuses a blank query without asking the provider" do
      assert {:error, :not_found} = Geocoding.geocode("")
      assert {:error, :not_found} = Geocoding.geocode("   ")
      assert {:error, :not_found} = Geocoding.geocode(nil)

      assert MockGeocoder.queries() == [],
             "a blank query reached the provider: #{inspect(MockGeocoder.queries())}"
    end
  end

  describe "Nominatim.handle/2" do
    test "parses coordinates that arrive as strings" do
      body = ~s([{"lat": "-33.9248685", "lon": "18.4240553"}])

      assert {:ok, %{latitude: lat, longitude: lng}} =
               Nominatim.handle({:ok, %Finch.Response{status: 200, body: body}}, "q")

      assert_in_delta lat, -33.9248685, 0.000001
      assert_in_delta lng, 18.4240553, 0.000001
    end

    test "an empty result list is not_found, not an error" do
      assert {:error, :not_found} =
               Nominatim.handle({:ok, %Finch.Response{status: 200, body: "[]"}}, "q")
    end

    test "a 200 with unparseable coordinates is a contract change, not a miss" do
      body = ~s([{"lat": "not-a-number", "lon": "18.42"}])

      assert {:error, :unexpected_response} =
               Nominatim.handle({:ok, %Finch.Response{status: 200, body: body}}, "q")
    end

    test "a malformed body is reported rather than crashing the caller" do
      assert {:error, :unexpected_response} =
               Nominatim.handle({:ok, %Finch.Response{status: 200, body: "not json"}}, "q")
    end

    test "a 429 is reported as rate_limited, distinctly from other HTTP errors" do
      assert {:error, :rate_limited} =
               Nominatim.handle({:ok, %Finch.Response{status: 429, body: ""}}, "q")
    end

    test "other HTTP statuses carry the status through" do
      assert {:error, {:http, 503}} =
               Nominatim.handle({:ok, %Finch.Response{status: 503, body: ""}}, "q")
    end

    test "a transport failure passes the reason through" do
      assert {:error, :timeout} = Nominatim.handle({:error, :timeout}, "q")
    end
  end
end
