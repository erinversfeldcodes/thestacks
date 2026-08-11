defmodule StacksWeb.InternalController do
  @moduledoc """
  Handles internal callbacks and smoke-test endpoints.

  ## Vision associate callback

  Protected by a timestamp-based HMAC scheme via the X-Vision-Signature header:
    Value: "<unix_timestamp_seconds>.<HMAC-SHA256(secret, "<ts>.POST.<path>")>" (lowercase hex)
    Valid window: ±60 seconds

  No user authentication — service-to-service only.
  Always returns 200 to the vision sidecar once auth passes (sidecar must not retry on app errors).

  ## Smoke test endpoint

  `POST /api/internal/smoke/circuit_breakers` — gated by `config :core, :smoke_tests_enabled`.
  Protected by the same `X-Internal-Token` HMAC scheme used by the scraper service.
  Returns 404 in production (default false).
  """

  use CoreWeb, :controller

  require Logger

  alias Stacks.AI.Client, as: AIClient
  alias Stacks.AI.TogetherClient
  alias Stacks.Books
  alias Stacks.Books.ISBNResolver
  alias Stacks.CircuitBreakers
  alias Stacks.Enrichment.ScraperClient
  alias Stacks.Proto.Vision.AssociateCallback

  @vision_path "/api/internal/vision/associate"
  @smoke_path "/api/internal/smoke/circuit_breakers"
  @replay_window_seconds 60

  @status_confirmed "ASSOCIATION_STATUS_CONFIRMED"
  @status_rejected "ASSOCIATION_STATUS_REJECTED"

  @doc "POST /api/internal/vision/associate — receive async cover association result."
  def vision_associate(conn, params) do
    if valid_vision_signature?(conn) do
      handle_association(conn, params)
    else
      conn
      |> put_status(401)
      |> json(%{error: "unauthorized"})
    end
  end

  @doc """
  POST /api/internal/smoke/circuit_breakers — smoke-test all 5 circuit breakers.

  Gated by `config :core, :smoke_tests_enabled, true`. Returns 404 if disabled.
  Protected by the `X-Internal-Token` HMAC scheme (same as scraper).

  Blows all 5 fuses via real failure paths, waits up to 60s for probe-driven
  recovery, and returns a structured JSON result.
  """
  def smoke_circuit_breakers(conn, _params) do
    if Application.get_env(:core, :smoke_tests_enabled, false) do
      run_smoke_circuit_breakers(conn)
    else
      conn
      |> put_status(404)
      |> json(%{error: "not found"})
    end
  end

  defp run_smoke_circuit_breakers(conn) do
    if valid_internal_token?(conn) do
      execute_smoke_test(conn)
    else
      conn
      |> put_status(401)
      |> json(%{error: "unauthorized"})
    end
  end

  defp execute_smoke_test(conn) do
    all_fuses = [
      :vision_fuse,
      :scraper_fuse,
      :together_ai_fuse,
      :open_library_fuse,
      :google_books_fuse
    ]

    original = save_original_config()

    Enum.each(all_fuses, fn name ->
      try do
        :fuse.remove(name)
      catch
        _, _ -> :ok
      end
    end)

    Enum.each(all_fuses, fn name ->
      :fuse.install(name, {{:standard, 1, 60_000}, {:reset, 30_000}})
    end)

    blow_all_fuses(original)

    blown_check =
      Enum.map(all_fuses, fn name ->
        {name, :fuse.ask(name, :sync) == :blown}
      end)

    not_blown = Enum.filter(blown_check, fn {_name, blown?} -> not blown? end)

    if not_blown != [] do
      CircuitBreakers.install_all()
      restore_original_config(original)

      conn
      |> put_status(500)
      |> json(%{
        result: "fail",
        error: "fuses not blown",
        not_blown: Enum.map(not_blown, fn {name, _} -> Atom.to_string(name) end)
      })
    else
      start_ms = System.monotonic_time(:millisecond)
      recovery_results = poll_for_recovery(all_fuses, start_ms, %{})

      CircuitBreakers.install_all()
      restore_original_config(original)

      all_recovered = Enum.all?(recovery_results, fn {_name, info} -> info.recovered end)
      result = if all_recovered, do: "pass", else: "fail"

      fuses_json =
        Map.new(recovery_results, fn {name, info} ->
          {Atom.to_string(name),
           %{blown: true, recovered: info.recovered, recovery_ms: info.recovery_ms}}
        end)

      conn
      |> put_status(200)
      |> json(%{result: result, fuses: fuses_json})
    end
  end

  defp blow_all_fuses(original) do
    Application.put_env(:core, :vision_service_url, "http://localhost:1")
    Application.put_env(:core, :vision_client, AIClient)

    for _ <- 1..2 do
      AIClient.call_vision("is_book", %{})
    end

    Application.put_env(:core, :vision_service_url, original.vision_service_url)
    Application.put_env(:core, :vision_client, original.vision_client)

    Application.put_env(:core, :scraper_service_url, "http://localhost:1")
    Application.put_env(:core, :scraper_client, ScraperClient)

    for _ <- 1..2 do
      ScraperClient.scrape("9780141439556", "test")
    end

    Application.put_env(:core, :scraper_service_url, original.scraper_service_url)
    Application.put_env(:core, :scraper_client, original.scraper_client)

    Application.put_env(:core, :together_ai_base_url, "http://localhost:1")
    Application.put_env(:core, :together_client, TogetherClient)
    Application.put_env(:core, :vision_together_api_key, "smoke-test-dummy-key")

    for _ <- 1..2 do
      TogetherClient.summarize_reviews("text", %{title: "T", author: "A"})
    end

    Application.put_env(:core, :together_ai_base_url, original.together_ai_base_url)
    Application.put_env(:core, :together_client, original.together_client)

    Application.put_env(:core, :isbn_http_client, Stacks.Testing.FailingHttpClient)

    for _ <- 1..2 do
      ISBNResolver.resolve("9780141439556")
    end

    Application.put_env(:core, :isbn_http_client, original.isbn_http_client)
  end

  defp save_original_config do
    %{
      vision_service_url: Application.get_env(:core, :vision_service_url),
      vision_client: Application.get_env(:core, :vision_client),
      scraper_service_url: Application.get_env(:core, :scraper_service_url),
      scraper_client: Application.get_env(:core, :scraper_client),
      together_ai_base_url: Application.get_env(:core, :together_ai_base_url),
      together_client: Application.get_env(:core, :together_client),
      vision_together_api_key: Application.get_env(:core, :vision_together_api_key),
      isbn_http_client: Application.get_env(:core, :isbn_http_client)
    }
  end

  defp restore_original_config(original) do
    Application.put_env(:core, :vision_service_url, original.vision_service_url)
    Application.put_env(:core, :vision_client, original.vision_client)
    Application.put_env(:core, :scraper_service_url, original.scraper_service_url)
    Application.put_env(:core, :scraper_client, original.scraper_client)
    Application.put_env(:core, :together_ai_base_url, original.together_ai_base_url)
    Application.put_env(:core, :together_client, original.together_client)

    if original.vision_together_api_key do
      Application.put_env(:core, :vision_together_api_key, original.vision_together_api_key)
    else
      Application.delete_env(:core, :vision_together_api_key)
    end

    Application.put_env(:core, :isbn_http_client, original.isbn_http_client)
  end

  # Poll all fuses every 500ms until all are :ok or 60s timeout.
  # Fast fuses recover via probe in ~15-35s; together_ai_fuse enters half-open
  # via {:reset, 30_000} backstop at ~30s. Typical completion: 30-35s.
  # Returns a map of %{fuse_name => %{recovered: bool, recovery_ms: integer}}.
  defp poll_for_recovery(fuses, start_ms, recovered_so_far) do
    elapsed = System.monotonic_time(:millisecond) - start_ms
    remaining_fuses = Enum.reject(fuses, fn name -> Map.has_key?(recovered_so_far, name) end)

    newly_recovered =
      Enum.filter(remaining_fuses, fn name ->
        :fuse.ask(name, :sync) == :ok
      end)

    now_ms = System.monotonic_time(:millisecond)

    updated =
      Enum.reduce(newly_recovered, recovered_so_far, fn name, acc ->
        Map.put(acc, name, %{recovered: true, recovery_ms: now_ms - start_ms})
      end)

    still_pending = Enum.reject(remaining_fuses, fn name -> name in newly_recovered end)

    cond do
      still_pending == [] ->
        updated

      elapsed >= 60_000 ->
        Enum.reduce(still_pending, updated, fn name, acc ->
          Map.put(acc, name, %{recovered: false, recovery_ms: 60_000})
        end)

      true ->
        Process.sleep(500)
        poll_for_recovery(fuses, start_ms, updated)
    end
  end

  defp handle_association(conn, params) do
    callback = %AssociateCallback{
      isbn: Map.get(params, "isbn", ""),
      book_id: Map.get(params, "book_id", ""),
      edition_id: Map.get(params, "edition_id", ""),
      status: Map.get(params, "status", ""),
      job_id: Map.get(params, "job_id", ""),
      reason: Map.get(params, "reason"),
      cover_image_url: Map.get(params, "cover_image_url", "")
    }

    case validate_callback(callback) do
      :ok ->
        dispatch_association(conn, callback)

      {:error, reason} ->
        Logger.warning("InternalController: invalid callback payload — #{reason}")
        json(conn, %{ok: true})
    end
  end

  defp validate_callback(%AssociateCallback{isbn: ""}),
    do: {:error, "isbn is required"}

  defp validate_callback(%AssociateCallback{job_id: ""}),
    do: {:error, "job_id is required"}

  defp validate_callback(%AssociateCallback{edition_id: ""}),
    do: {:error, "edition_id is required"}

  defp validate_callback(%AssociateCallback{status: ""}),
    do: {:error, "status is required"}

  defp validate_callback(%AssociateCallback{
         status: @status_confirmed,
         cover_image_url: ""
       }),
       do: {:error, "cover_image_url is required for confirmed status"}

  defp validate_callback(%AssociateCallback{
         status: @status_confirmed,
         cover_image_url: url
       })
       when is_binary(url) and byte_size(url) > 0 do
    if String.starts_with?(url, "http://") or String.starts_with?(url, "https://") do
      :ok
    else
      {:error, "cover_image_url must use http or https scheme"}
    end
  end

  defp validate_callback(_callback), do: :ok

  defp dispatch_association(conn, %AssociateCallback{
         status: @status_confirmed,
         edition_id: edition_id,
         cover_image_url: cover_url
       }) do
    case Books.confirm_cover_association(edition_id, cover_url) do
      {:ok, _edition} ->
        json(conn, %{ok: true})

      {:error, :not_found} ->
        Logger.warning(
          "InternalController: edition #{edition_id} not found for cover confirmation"
        )

        json(conn, %{ok: true})

      {:error, reason} ->
        Logger.error(
          "InternalController: failed to confirm cover for edition #{edition_id}: #{inspect(reason)}"
        )

        json(conn, %{ok: true})
    end
  end

  defp dispatch_association(conn, %AssociateCallback{
         status: @status_rejected,
         edition_id: edition_id,
         reason: reason
       }) do
    reason_suffix = if is_binary(reason) and reason != "", do: ": #{reason}", else: ""

    Logger.warning(
      "InternalController: cover association rejected for edition #{edition_id}#{reason_suffix}"
    )

    json(conn, %{ok: true})
  end

  defp dispatch_association(conn, %AssociateCallback{status: status}) do
    Logger.warning("InternalController: unknown status #{inspect(status)} received")

    :telemetry.execute(
      [:stacks, :vision, :unknown_association_status],
      %{count: 1},
      %{status: status}
    )

    json(conn, %{ok: true})
  end

  defp valid_vision_signature?(conn) do
    case get_req_header(conn, "x-vision-signature") do
      [provided] -> verify_vision_token(provided)
      _ -> false
    end
  end

  defp verify_vision_token(provided) do
    case String.split(provided, ".", parts: 2) do
      [ts_str, provided_sig] -> verify_vision_hmac(ts_str, provided_sig)
      _ -> false
    end
  end

  defp verify_vision_hmac(ts_str, provided_sig) do
    with {ts, ""} <- Integer.parse(ts_str),
         now = System.os_time(:second),
         true <- abs(now - ts) <= @replay_window_seconds,
         secret when not is_nil(secret) <-
           Application.get_env(:core, :vision_hmac_secret) do
      message = "#{ts_str}.POST.#{@vision_path}"
      expected = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)
      Plug.Crypto.secure_compare(expected, provided_sig)
    else
      :error ->
        Logger.warning("InternalController: X-Vision-Signature has non-numeric timestamp")
        false

      false ->
        Logger.warning(
          "InternalController: X-Vision-Signature timestamp outside ±60s replay window"
        )

        false

      nil ->
        Logger.error("InternalController: vision_hmac_secret not configured — rejecting request")
        false
    end
  end

  defp valid_internal_token?(conn) do
    case get_req_header(conn, "x-internal-token") do
      [provided] -> verify_internal_token(provided)
      _ -> false
    end
  end

  defp verify_internal_token(provided) do
    case String.split(provided, ".", parts: 2) do
      [ts_str, provided_sig] -> verify_internal_hmac(ts_str, provided_sig)
      _ -> false
    end
  end

  defp verify_internal_hmac(ts_str, provided_sig) do
    with {ts, ""} <- Integer.parse(ts_str),
         now = System.os_time(:second),
         true <- abs(now - ts) <= @replay_window_seconds,
         secret when not is_nil(secret) <-
           Application.get_env(:core, :scraper_hmac_secret) do
      message = "#{ts_str}.POST.#{@smoke_path}"
      expected = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)
      Plug.Crypto.secure_compare(expected, provided_sig)
    else
      :error ->
        Logger.warning("InternalController: X-Internal-Token has non-numeric timestamp")
        false

      false ->
        Logger.warning(
          "InternalController: X-Internal-Token timestamp outside ±60s replay window"
        )

        false

      nil ->
        Logger.error("InternalController: scraper_hmac_secret not configured — rejecting request")
        false
    end
  end
end
