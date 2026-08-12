defmodule StacksWeb.TransparencyControllerTest do
  @moduledoc """
      Tests for the public transparency metrics endpoint.

      `GET /api/transparency/metrics` is unauthenticated and curated: it returns
      `{live, durable, generated_at, cache_ttl}` with teaching metadata per entry,
      and never exposes PII or a de-anonymisable dimension.
  """

  use CoreWeb.ConnCase, async: false

  alias Stacks.Transparency.{Cache, MockPrometheusClient}

  setup do
    Cache.invalidate_all()
    MockPrometheusClient.reset()
    :ok
  end

  describe "GET /api/transparency/metrics" do
    test "returns 200 with the curated shape — no auth required", %{conn: conn} do
      MockPrometheusClient.put_response({:ok, 1.25})

      response =
        conn
        |> get("/api/transparency/metrics")
        |> json_response(200)

      assert Map.has_key?(response, "live")
      assert is_list(response["durable"])
      assert is_binary(response["generated_at"])
      assert is_integer(response["cache_ttl"])
    end

    test "each entry carries what/how/why teaching metadata", %{conn: conn} do
      MockPrometheusClient.put_response({:ok, 2.0})

      response =
        conn
        |> get("/api/transparency/metrics")
        |> json_response(200)

      entries = List.wrap(response["live"]) ++ response["durable"]
      entries = Enum.filter(entries, &is_map/1)
      refute Enum.empty?(entries)

      Enum.each(entries, fn entry ->
        assert is_binary(entry["what"])
        assert is_binary(entry["how"])
        assert is_binary(entry["why"])
        assert is_binary(entry["label"])
      end)
    end

    test "payload exposes no PII / de-anonymisable field", %{conn: conn} do
      MockPrometheusClient.put_response({:ok, 2.0})

      response =
        conn
        |> get("/api/transparency/metrics")
        |> json_response(200)

      body = response |> Jason.encode!() |> String.downcase()

      for forbidden <- ~w(user_id email password ip_address audible linked_account) do
        refute String.contains?(body, forbidden)
      end

      for forbidden_key <- ~w(handle user ip name) do
        refute String.contains?(body, "\"#{forbidden_key}\":")
      end
    end

    test "degrades to an unavailable live section when Prometheus errors", %{conn: conn} do
      MockPrometheusClient.put_response({:error, :not_configured})

      response =
        conn
        |> get("/api/transparency/metrics")
        |> json_response(200)

      assert response["live"] == "unavailable"
      assert is_list(response["durable"])
      refute Enum.empty?(response["durable"])
    end
  end
end
