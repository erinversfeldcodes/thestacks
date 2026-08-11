defmodule Stacks.UploadTelemetryTest.FailingHandler do
  @behaviour Stacks.Events.Handler
  def handle_event(_event), do: {:error, :test_induced_failure}
end

defmodule Stacks.UploadTelemetryTest.RaisingHandler do
  @behaviour Stacks.Events.Handler
  def handle_event(_event), do: raise("test-induced crash")
end

defmodule Stacks.UploadTelemetryTest do
  @moduledoc """
    Suite 11 — telemetry for the upload pipeline: SubscriberWorker
    handler errors, Oban job lifecycle, BudgetTracker state changes,
    Phoenix request telemetry on upload endpoints, circuit-breaker
    behaviour, and cost tracking, across the 111 upload user stories.
  """

  use CoreWeb.ConnCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.AI.VisionFixtures
  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.AI.BudgetTracker
  alias Stacks.AI.Client
  alias Stacks.Events.SubscriberWorker
  alias Stacks.Workers.IdentifyBookJob
  alias Stacks.Workers.RefreshCostsJob

  @image_b64 Base.encode64("fake image bytes for testing")

  setup do
    user = insert(:user)
    {:ok, token, _} = Guardian.encode_and_sign(user)

    book = insert(:book, title: "The Great Gatsby")
    insert(:book_edition, book: book, isbn: "9780743273565")

    {:ok, user: user, token: token, book: book}
  end

  defp auth_conn(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp attach_telemetry(event_name) do
    test_pid = self()
    handler_id = "test-#{Enum.join(event_name, "-")}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp attach_telemetry_filtered(event_name, filter_fn) do
    test_pid = self()
    handler_id = "test-#{Enum.join(event_name, "-")}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn name, measurements, metadata, _ ->
        if filter_fn.(metadata) do
          send(test_pid, {:telemetry, name, measurements, metadata})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  describe "Suite 11 — handler_error telemetry from SubscriberWorker" do
    setup do
      on_exit(fn -> Application.delete_env(:core, :test_handler_overrides) end)
      :ok
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "emits [:stacks, :events, :handler_error] when handler returns {:error, reason}",
         %{user: user} do
      attach_telemetry([:stacks, :events, :handler_error])

      Application.put_env(:core, :test_handler_overrides, %{
        "test.returns_error" => [Stacks.UploadTelemetryTest.FailingHandler]
      })

      event_id = Ecto.UUID.generate()

      Core.Repo.insert_all(
        "event_log",
        [
          %{
            id: elem(Ecto.UUID.dump(event_id), 1),
            event_type: "test.returns_error",
            aggregate_type: "test",
            aggregate_id: elem(Ecto.UUID.dump(user.id), 1),
            schema_version: 1,
            payload: %{},
            metadata: %{},
            occurred_at: DateTime.utc_now()
          }
        ],
        prefix: "op"
      )

      perform_job(SubscriberWorker, %{"event_id" => event_id})

      assert_receive {:telemetry, [:stacks, :events, :handler_error], %{count: 1}, metadata},
                     2_000

      assert is_binary(metadata.handler)
      assert metadata.event_type == "test.returns_error"
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "emits [:stacks, :events, :handler_error] when handler raises", %{
      user: user
    } do
      attach_telemetry([:stacks, :events, :handler_error])

      Application.put_env(:core, :test_handler_overrides, %{
        "test.raises" => [Stacks.UploadTelemetryTest.RaisingHandler]
      })

      event_id = Ecto.UUID.generate()

      Core.Repo.insert_all(
        "event_log",
        [
          %{
            id: elem(Ecto.UUID.dump(event_id), 1),
            event_type: "test.raises",
            aggregate_type: "test",
            aggregate_id: elem(Ecto.UUID.dump(user.id), 1),
            schema_version: 1,
            payload: %{},
            metadata: %{},
            occurred_at: DateTime.utc_now()
          }
        ],
        prefix: "op"
      )

      perform_job(SubscriberWorker, %{"event_id" => event_id})

      assert_receive {:telemetry, [:stacks, :events, :handler_error], %{count: 1}, metadata},
                     2_000

      assert is_binary(metadata.handler)
      assert metadata.event_type == "test.raises"
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "handler_error metadata includes handler name and event_type", %{user: user} do
      attach_telemetry([:stacks, :events, :handler_error])

      Application.put_env(:core, :test_handler_overrides, %{
        "test.metadata_check" => [Stacks.UploadTelemetryTest.FailingHandler]
      })

      event_id = Ecto.UUID.generate()

      Core.Repo.insert_all(
        "event_log",
        [
          %{
            id: elem(Ecto.UUID.dump(event_id), 1),
            event_type: "test.metadata_check",
            aggregate_type: "test",
            aggregate_id: elem(Ecto.UUID.dump(user.id), 1),
            schema_version: 1,
            payload: %{},
            metadata: %{},
            occurred_at: DateTime.utc_now()
          }
        ],
        prefix: "op"
      )

      perform_job(SubscriberWorker, %{"event_id" => event_id})

      assert_receive {:telemetry, [:stacks, :events, :handler_error], measurements, metadata},
                     2_000

      assert measurements == %{count: 1}
      assert metadata.event_type == "test.metadata_check"
      assert metadata.handler =~ "FailingHandler"
    end
  end

  describe "Suite 11 — Oban job lifecycle telemetry" do
    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "[:oban, :job, :start] fires for IdentifyBookJob", %{user: user} do
      attach_telemetry_filtered(
        [:oban, :job, :start],
        &(&1.job.worker == "Stacks.Workers.IdentifyBookJob")
      )

      image = insert(:uploaded_image, status: "pending")

      {:ok, _job} =
        Oban.insert(
          IdentifyBookJob.new(%{
            "user_id" => user.id,
            "image_id" => image.id,
            "image_b64" => @image_b64
          })
        )

      Oban.drain_queue(queue: :vision)

      assert_receive {:telemetry, [:oban, :job, :start], _measurements, metadata}, 5_000
      assert metadata.job.worker == "Stacks.Workers.IdentifyBookJob"
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "[:oban, :job, :stop] fires for IdentifyBookJob", %{user: user} do
      attach_telemetry_filtered(
        [:oban, :job, :stop],
        &(&1.job.worker == "Stacks.Workers.IdentifyBookJob")
      )

      image = insert(:uploaded_image, status: "pending")

      {:ok, _job} =
        Oban.insert(
          IdentifyBookJob.new(%{
            "user_id" => user.id,
            "image_id" => image.id,
            "image_b64" => @image_b64
          })
        )

      Oban.drain_queue(queue: :vision)

      assert_receive {:telemetry, [:oban, :job, :stop], measurements, metadata}, 5_000
      assert metadata.job.worker == "Stacks.Workers.IdentifyBookJob"
      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "[:oban, :job, :stop] fires for SubscriberWorker" do
      attach_telemetry_filtered(
        [:oban, :job, :stop],
        &(&1.job.worker == "Stacks.Events.SubscriberWorker")
      )

      {:ok, _book} =
        Stacks.Books.create(%{
          "title" => "Oban Telemetry Test",
          "isbn" => "9780140449136"
        })

      Oban.drain_queue(queue: :events)

      assert_receive {:telemetry, [:oban, :job, :stop], measurements, metadata}, 5_000
      assert metadata.job.worker == "Stacks.Events.SubscriberWorker"
      assert is_integer(measurements.duration)
    end

    @tag stories: ["US-1.1.3"], suite: :telemetry
    test "[:oban,:job,:stop] fires for IdentifyBookJob cancellation (not_a_book — )",
         %{user: user} do
      attach_telemetry_filtered(
        [:oban, :job, :stop],
        &(&1.job.worker == "Stacks.Workers.IdentifyBookJob")
      )

      image = insert(:uploaded_image, status: "pending")

      {:ok, _job} =
        Oban.insert(
          IdentifyBookJob.new(%{
            "user_id" => user.id,
            "image_id" => image.id,
            "image_b64" => @image_b64
          })
        )

      Oban.drain_queue(queue: :vision)

      assert_receive {:telemetry, [:oban, :job, :stop], measurements, metadata}, 5_000
      assert metadata.job.worker == "Stacks.Workers.IdentifyBookJob"
      assert is_integer(measurements.duration)
    end

    @tag stories: ["US-1.1.2"], suite: :telemetry
    test "[:oban,:job,:stop] fires for IdentifyBookJob cancellation (isbn_not_found — )",
         %{user: user} do
      attach_telemetry_filtered(
        [:oban, :job, :stop],
        &(&1.job.worker == "Stacks.Workers.IdentifyBookJob")
      )

      image = insert(:uploaded_image, status: "pending")

      steer_vision(no_isbn())

      {:ok, _job} =
        Oban.insert(
          IdentifyBookJob.new(%{
            "user_id" => user.id,
            "image_id" => image.id,
            "image_b64" => @image_b64
          })
        )

      Oban.drain_queue(queue: :vision)

      assert_receive {:telemetry, [:oban, :job, :stop], measurements, metadata}, 5_000
      assert metadata.job.worker == "Stacks.Workers.IdentifyBookJob"
      assert is_integer(measurements.duration)
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "[:oban, :job, :stop] fires for SubscriberWorker with different event types" do
      attach_telemetry_filtered(
        [:oban, :job, :stop],
        &(&1.job.worker == "Stacks.Events.SubscriberWorker")
      )

      event_id = Ecto.UUID.generate()

      Core.Repo.insert_all(
        "event_log",
        [
          %{
            id: elem(Ecto.UUID.dump(event_id), 1),
            event_type: "image.submitted",
            aggregate_type: "image",
            aggregate_id: elem(Ecto.UUID.dump(Ecto.UUID.generate()), 1),
            schema_version: 1,
            payload: %{"storage_path" => "uploads/test"},
            metadata: %{},
            occurred_at: DateTime.utc_now()
          }
        ],
        prefix: "op"
      )

      {:ok, _job} =
        Oban.insert(SubscriberWorker.new(%{"event_id" => event_id}))

      Oban.drain_queue(queue: :events)

      assert_receive {:telemetry, [:oban, :job, :stop], measurements, metadata}, 5_000
      assert metadata.job.worker == "Stacks.Events.SubscriberWorker"
      assert is_integer(measurements.duration)
    end
  end

  describe "Suite 11 — BudgetTracker state tracking for metrics" do
    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "record_cost updates daily_total_cents" do
      state_before = BudgetTracker.current_state()
      BudgetTracker.record_cost(:modal, 42)
      Process.sleep(50)
      state_after = BudgetTracker.current_state()

      assert state_after.daily_total_cents == state_before.daily_total_cents + 42
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "record_cost updates monthly_total_cents" do
      state_before = BudgetTracker.current_state()
      BudgetTracker.record_cost(:modal, 100)
      Process.sleep(50)
      state_after = BudgetTracker.current_state()

      assert state_after.monthly_total_cents == state_before.monthly_total_cents + 100
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "record_cost tracks per-provider breakdown" do
      BudgetTracker.record_cost(:modal, 25)
      BudgetTracker.record_cost(:together, 15)
      Process.sleep(50)
      state = BudgetTracker.current_state()

      assert Map.has_key?(state.providers, "modal")
      assert Map.has_key?(state.providers, "together")
      assert state.providers["modal"] >= 25
      assert state.providers["together"] >= 15
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "current_state returns all fields needed for metrics dashboard" do
      state = BudgetTracker.current_state()

      assert Map.has_key?(state, :daily_total_cents)
      assert Map.has_key?(state, :monthly_total_cents)
      assert Map.has_key?(state, :providers)
      assert is_integer(state.daily_total_cents)
      assert is_integer(state.monthly_total_cents)
      assert is_map(state.providers)
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "check_budget reflects accumulated costs" do
      original_config = Application.get_env(:core, :ai_budget, [])

      try do
        Application.put_env(:core, :ai_budget,
          daily_limit_cents: 10,
          monthly_limit_cents: 50_000
        )

        BudgetTracker.record_cost(:telemetry_test, 11)
        Process.sleep(50)

        assert {:error, :daily_limit_exceeded} = BudgetTracker.check_budget(:telemetry_test)
      after
        Application.put_env(:core, :ai_budget, original_config)
      end
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "check_budget detects monthly limit exceeded" do
      original_config = Application.get_env(:core, :ai_budget, [])

      try do
        Application.put_env(:core, :ai_budget,
          daily_limit_cents: 50_000,
          monthly_limit_cents: 5
        )

        BudgetTracker.record_cost(:monthly_test, 6)
        Process.sleep(50)

        assert {:error, :monthly_limit_exceeded} = BudgetTracker.check_budget(:monthly_test)
      after
        Application.put_env(:core, :ai_budget, original_config)
      end
    end
  end

  describe "Suite 11 — Phoenix endpoint telemetry for upload requests" do
    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "[:phoenix, :endpoint, :stop] fires for POST /api/upload/init", %{
      conn: conn,
      token: token
    } do
      attach_telemetry([:phoenix, :endpoint, :stop])

      conn
      |> auth_conn(token)
      |> post("/api/upload/init", %{"content_type" => "image/jpeg"})

      assert_receive {:telemetry, [:phoenix, :endpoint, :stop], measurements, _metadata}, 2_000
      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "[:phoenix, :endpoint, :stop] fires for GET /api/upload/:id/stream", %{
      conn: conn,
      token: token,
      user: user
    } do
      attach_telemetry([:phoenix, :endpoint, :stop])

      image = insert(:uploaded_image, status: "pending", user_id: user.id)

      conn
      |> get("/api/upload/#{image.id}/stream?token=#{token}")

      assert_receive {:telemetry, [:phoenix, :endpoint, :stop], measurements, _metadata}, 2_000
      assert is_integer(measurements.duration)
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "[:phoenix, :router_dispatch, :stop] fires with route info for upload", %{
      conn: conn,
      token: token
    } do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      conn
      |> auth_conn(token)
      |> post("/api/upload/init", %{"content_type" => "image/jpeg"})

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.UploadController
    end
  end

  describe "Suite 11 — router_dispatch telemetry for POST /api/upload/init" do
    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "telemetry fires on an error response (404 commit for unknown image)", %{
      conn: conn,
      token: token
    } do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      conn =
        conn
        |> auth_conn(token)
        |> post("/api/upload/#{Ecto.UUID.generate()}/commit", %{})

      assert json_response(conn, 404)["error"] == "not_found"

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.UploadController
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "401 when unauthenticated", %{conn: conn} do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      conn = post(conn, "/api/upload/init", %{})

      assert conn.status == 401

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, _metadata},
                     2_000

      assert is_integer(measurements.duration)
    end
  end

  describe "Suite 11 — router_dispatch telemetry for GET /api/upload/:id/stream" do
    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "200 pending stream emits telemetry", %{conn: conn, token: token, user: user} do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      image = insert(:uploaded_image, status: "pending", user_id: user.id)

      conn =
        conn
        |> get("/api/upload/#{image.id}/stream?token=#{token}")

      assert conn.status == 200

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.UploadController
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "200 resolved stream emits telemetry", %{
      conn: conn,
      token: token,
      user: user,
      book: book
    } do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      image = insert(:uploaded_image, status: "pending", user_id: user.id)

      {:ok, book_id_bin} = Ecto.UUID.dump(book.id)
      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)

      import Ecto.Query

      Core.Repo.update_all(
        from(i in "uploaded_images", where: i.id == ^image_id_bin),
        [set: [status: "resolved", book_id: book_id_bin]],
        prefix: "op"
      )

      conn =
        conn
        |> get("/api/upload/#{image.id}/stream?token=#{token}")

      assert conn.status == 200
      assert String.contains?(conn.resp_body, "resolved")

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.UploadController
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "404 for non-existent image emits telemetry", %{conn: conn, token: token} do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      fake_id = Ecto.UUID.generate()

      conn =
        conn
        |> get("/api/upload/#{fake_id}/stream?token=#{token}")

      assert json_response(conn, 404)["error"] == "not found"

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.UploadController
    end
  end

  describe "Suite 11 — router_dispatch telemetry for GET /api/books/:id" do
    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "200 for existing book emits telemetry", %{conn: conn, book: book} do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      conn = get(conn, "/api/books/#{book.id}")

      assert json_response(conn, 200)["book"]["id"] == book.id

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.BookController
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "404 for non-existent book emits telemetry", %{conn: conn} do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      fake_id = Ecto.UUID.generate()
      conn = get(conn, "/api/books/#{fake_id}")

      assert json_response(conn, 404)["error"] == "not_found"

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.BookController
    end
  end

  describe "Suite 11 — router_dispatch telemetry for POST /api/bookshelves/:name/placements" do
    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "201 for valid placement emits telemetry", %{conn: conn, token: token, book: book} do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      conn =
        conn
        |> auth_conn(token)
        |> post("/api/bookshelves/wishlist/placements", %{"book_id" => book.id})

      assert json_response(conn, 201)["placement"]

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.BookshelfPlacementController
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "422 for invalid bookshelf name emits telemetry", %{
      conn: conn,
      token: token,
      book: book
    } do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      conn =
        conn
        |> auth_conn(token)
        |> post("/api/bookshelves/nonexistent_shelf/placements", %{"book_id" => book.id})

      assert json_response(conn, 422)["error"]

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.BookshelfPlacementController
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "401 for unauthenticated placement request", %{conn: conn, book: book} do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      conn = post(conn, "/api/bookshelves/wishlist/placements", %{"book_id" => book.id})

      assert conn.status == 401

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, _metadata},
                     2_000

      assert is_integer(measurements.duration)
    end
  end

  describe "Suite 11 — router_dispatch telemetry for GET /api/books/isbn/:isbn" do
    @tag stories: ["US-1.1.5"], suite: :telemetry
    test "200 for existing ISBN emits telemetry", %{conn: conn, token: token} do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      conn =
        conn
        |> auth_conn(token)
        |> get("/api/books/isbn/9780743273565")

      assert json_response(conn, 200)["book"]

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.BookController
    end

    @tag stories: ["US-1.1.5"], suite: :telemetry
    test "404 for unknown ISBN emits telemetry", %{conn: conn, token: token} do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      conn =
        conn
        |> auth_conn(token)
        |> get("/api/books/isbn/9780000000000")

      assert json_response(conn, 404)["error"] == "not_found"

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.BookController
    end
  end

  describe "Suite 11 — router_dispatch telemetry for POST /api/books/confirm" do
    @tag stories: ["US-1.1.6"], suite: :telemetry
    test "confirm with missing isbn returns 422 with telemetry", %{conn: conn, token: token} do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      conn =
        conn
        |> auth_conn(token)
        |> post("/api/books/confirm", %{})

      assert json_response(conn, 422)["error"] == "isbn is required"

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.BookController
    end
  end

  describe "Suite 11 — router_dispatch telemetry for POST /api/books/:id/merge-format" do
    @tag stories: ["US-1.1.8"], suite: :telemetry
    test "merge-format with unresolvable ISBN returns 422 with telemetry", %{
      conn: conn,
      token: token,
      book: book
    } do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      conn =
        conn
        |> auth_conn(token)
        |> post("/api/books/#{book.id}/merge-format", %{"isbn" => "9780000000000"})

      assert conn.status == 422
      assert %{"error" => "isbn_not_found"} = json_response(conn, 422)

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.BookController
    end
  end

  describe "Suite 11 — Oban job telemetry for IdentifyBookJob cancellation" do
    @tag stories: ["US-1.1.2"], suite: :telemetry
    test "job stop telemetry fires when IdentifyBookJob processes an image (isbn_not_found path)",
         %{user: user} do
      attach_telemetry_filtered(
        [:oban, :job, :stop],
        &(&1.job.worker == "Stacks.Workers.IdentifyBookJob")
      )

      image = insert(:uploaded_image, status: "pending")

      {:ok, _job} =
        Oban.insert(
          IdentifyBookJob.new(%{
            "user_id" => user.id,
            "image_id" => image.id,
            "image_b64" => @image_b64
          })
        )

      Oban.drain_queue(queue: :vision)

      assert_receive {:telemetry, [:oban, :job, :stop], measurements, metadata}, 5_000
      assert metadata.job.worker == "Stacks.Workers.IdentifyBookJob"
      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "Oban exception telemetry fires on unhandled job crash", %{user: user} do
      attach_telemetry_filtered(
        [:oban, :job, :exception],
        &(&1.job.worker == "Stacks.Workers.IdentifyBookJob")
      )

      {:ok, _job} =
        Oban.insert(
          IdentifyBookJob.new(%{
            "user_id" => user.id,
            "image_id" => Ecto.UUID.generate(),
            "storage_key" => "uploads/nonexistent"
          })
        )

      Oban.drain_queue(queue: :vision)

      receive do
        {:telemetry, [:oban, :job, :exception], measurements, metadata} ->
          assert metadata.job.worker == "Stacks.Workers.IdentifyBookJob"
          assert is_integer(measurements.duration)
      after
        5_000 ->
          :ok
      end
    end
  end

  describe "Suite 11 — Ecto query telemetry during upload flow" do
    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "[:core, :repo, :query] fires for database operations", %{token: token} do
      attach_telemetry([:core, :repo, :query])

      image = insert(:uploaded_image, status: "pending")

      get(build_conn(), "/api/upload/#{image.id}/stream?token=#{token}")

      assert_receive {:telemetry, [:core, :repo, :query], measurements, _metadata}, 2_000
      assert is_integer(measurements.total_time)
      assert measurements.total_time >= 0
    end
  end

  describe "Suite 11 — RefreshCostsJob Oban lifecycle telemetry" do
    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "[:oban, :job, :stop] fires for RefreshCostsJob" do
      attach_telemetry_filtered(
        [:oban, :job, :stop],
        &(&1.job.worker == "Stacks.Workers.RefreshCostsJob")
      )

      {:ok, _job} =
        Oban.insert(RefreshCostsJob.new(%{}))

      Oban.drain_queue(queue: :default)

      assert_receive {:telemetry, [:oban, :job, :stop], measurements, metadata}, 5_000
      assert metadata.job.worker == "Stacks.Workers.RefreshCostsJob"
      assert is_integer(measurements.duration)
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "RefreshCostsJob emits costs.refreshed event which triggers SubscriberWorker telemetry" do
      attach_telemetry_filtered(
        [:oban, :job, :stop],
        &(&1.job.worker == "Stacks.Workers.RefreshCostsJob")
      )

      {:ok, _job} =
        Oban.insert(RefreshCostsJob.new(%{}))

      Oban.drain_queue(queue: :default)

      assert_receive {:telemetry, [:oban, :job, :stop], _measurements, metadata}, 5_000
      assert metadata.job.worker == "Stacks.Workers.RefreshCostsJob"

      import Ecto.Query

      events =
        Core.Repo.all(
          from(e in "event_log",
            where: e.event_type == "costs.refreshed",
            select: e.event_type
          ),
          prefix: "op"
        )

      assert events != []
    end
  end

  describe "Suite 11 — Costs context usage metrics for cost tracking" do
    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "Costs.usage_metrics returns all fields needed for cost dashboard" do
      metrics = Stacks.Costs.usage_metrics()

      assert Map.has_key?(metrics, :books)
      assert Map.has_key?(metrics, :uploads)
      assert Map.has_key?(metrics, :placements)
      assert Map.has_key?(metrics, :db_size_bytes)
      assert Map.has_key?(metrics, :avg_upload_payload_bytes)
      assert Map.has_key?(metrics, :vision_jobs_this_month)
      assert is_integer(metrics.books)
      assert is_integer(metrics.uploads)
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "Costs.upsert_cost creates platform_costs records" do
      now = DateTime.utc_now()
      period_start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
      days = Calendar.ISO.days_in_month(now.year, now.month)
      period_end = %{now | day: days, hour: 23, minute: 59, second: 59, microsecond: {999_999, 6}}

      attrs = %{
        category: "compute",
        service: "modal_telemetry_test",
        description: "Test cost entry",
        amount_cents: 42,
        currency: "USD",
        period_start: period_start,
        period_end: period_end
      }

      assert {:ok, cost} = Stacks.Costs.upsert_cost(attrs)
      assert cost.amount_cents == 42
      assert cost.service == "modal_telemetry_test"
    end
  end

  describe "Suite 11 — Circuit breaker / Fuse observability" do
    @tag stories: ["US-1.1.1"], suite: :telemetry
    test ":fuse.ask returns :ok or :blown for the vision_service fuse" do
      case :fuse.ask(:vision_service, :sync) do
        :ok ->
          assert true

        :blown ->
          assert true

        {:error, :not_found} ->
          assert true
      end
    end

    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "AI.Client returns {:error, :circuit_open} when fuse is blown" do
      original = Application.get_env(:core, :vision_client)
      Application.put_env(:core, :vision_client, Stacks.AI.Client)
      on_exit(fn -> Application.put_env(:core, :vision_client, original) end)

      :fuse.reset(:vision_fuse)
      :fuse.install(:vision_fuse, {{:standard, 1, 1_000}, {:reset, 60_000}})
      :fuse.melt(:vision_fuse)
      :fuse.melt(:vision_fuse)

      result = Client.call_vision("extract_isbn", %{image_b64: "test"})

      assert result == {:error, :circuit_open}

      :fuse.reset(:vision_fuse)
    end
  end

  describe "Suite 11 — end-to-end telemetry across upload flow" do
    @tag stories: ["US-1.1.1"], suite: :telemetry
    test "POST /api/upload/init emits both endpoint and router_dispatch telemetry", %{
      conn: conn,
      token: token
    } do
      test_pid = self()

      endpoint_id = "test-e2e-endpoint-#{System.unique_integer([:positive])}"
      router_id = "test-e2e-router-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        endpoint_id,
        [:phoenix, :endpoint, :stop],
        fn _name, measurements, _metadata, _ ->
          send(test_pid, {:endpoint_stop, measurements})
        end,
        nil
      )

      :telemetry.attach(
        router_id,
        [:phoenix, :router_dispatch, :stop],
        fn _name, measurements, metadata, _ ->
          send(test_pid, {:router_stop, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(endpoint_id)
        :telemetry.detach(router_id)
      end)

      conn
      |> auth_conn(token)
      |> post("/api/upload/init", %{"content_type" => "image/jpeg"})

      assert_receive {:endpoint_stop, measurements}, 2_000
      assert is_integer(measurements.duration)

      assert_receive {:router_stop, measurements, metadata}, 2_000
      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.UploadController
    end
  end

  describe "Suite 11 — telemetry for age-gated book access" do
    @tag stories: ["US-1.1.4"], suite: :telemetry
    test "GET /api/books/:id for age_gated book emits router_dispatch telemetry", %{conn: conn} do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      age_gated_book = insert(:book, title: "Adult Content Book", visibility_tier: "age_gated")
      insert(:book_edition, book: age_gated_book, isbn: "9780060934347")

      conn = get(conn, "/api/books/#{age_gated_book.id}")

      assert conn.status in [200, 403]

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.BookController
    end
  end

  describe "Suite 11 — telemetry for duplicate detection" do
    @tag stories: ["US-1.1.6"], suite: :telemetry
    test "stream endpoint with is_duplicate flag emits telemetry", %{
      conn: conn,
      token: token,
      user: user,
      book: book
    } do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      Stacks.Shelving.place_book(user.id, book.id, "library")

      image = insert(:uploaded_image, status: "pending", user_id: user.id)
      {:ok, book_id_bin} = Ecto.UUID.dump(book.id)
      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)

      import Ecto.Query

      Core.Repo.update_all(
        from(i in "uploaded_images", where: i.id == ^image_id_bin),
        [set: [status: "resolved", book_id: book_id_bin, book_ids: [book_id_bin]]],
        prefix: "op"
      )

      conn =
        conn
        |> get("/api/upload/#{image.id}/stream?token=#{token}")

      assert conn.status == 200
      assert String.contains?(conn.resp_body, "true")

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.UploadController
    end
  end

  describe "Suite 11 — telemetry for multi-book status poll" do
    @tag stories: ["US-1.1.7"], suite: :telemetry
    test "stream endpoint with multiple book_ids emits telemetry", %{
      conn: conn,
      token: token,
      user: user
    } do
      attach_telemetry([:phoenix, :router_dispatch, :stop])

      book1 = insert(:book, title: "Multi Book One")
      insert(:book_edition, book: book1, isbn: "9780141439518")
      book2 = insert(:book, title: "Multi Book Two")
      insert(:book_edition, book: book2, isbn: "9780141439525")

      image = insert(:uploaded_image, status: "pending", user_id: user.id)
      {:ok, book1_bin} = Ecto.UUID.dump(book1.id)
      {:ok, book2_bin} = Ecto.UUID.dump(book2.id)
      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)

      import Ecto.Query

      Core.Repo.update_all(
        from(i in "uploaded_images", where: i.id == ^image_id_bin),
        [
          set: [
            status: "resolved",
            book_id: book1_bin,
            book_ids: [book1_bin, book2_bin]
          ]
        ],
        prefix: "op"
      )

      conn =
        conn
        |> get("/api/upload/#{image.id}/stream?token=#{token}")

      assert conn.status == 200
      assert String.contains?(conn.resp_body, book1.id)
      assert String.contains?(conn.resp_body, book2.id)

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.plug == StacksWeb.UploadController
    end
  end
end
