defmodule Stacks.UploadTerminalTelemetryTest do
  @moduledoc """
  Tests for the upload terminal counter (Issue #136 Phase 1, DoD #3).

  Every `uploaded_image` status transition to a terminal state must emit:

      [:stacks, :upload, :terminal]
      measurements: %{count: 1}
      metadata:     %{outcome: :resolved | :rejected | :timeout}

  Non-terminal transitions (e.g., pending → pending) must NOT emit this event.

  The `IdentifyBookJob` worker is the canonical path to `:resolved` / `:rejected`.
  `:timeout` is reached from the upload SSE stream in `UploadController`. Both
  must fire the new telemetry event.
  """

  # async: false — telemetry handlers are global; we also race against Oban.
  use CoreWeb.ConnCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Workers.IdentifyBookJob

  @image_b64 Base.encode64("fake image bytes for testing")

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp attach_terminal_handler do
    test_pid = self()
    handler_id = "terminal-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:stacks, :upload, :terminal],
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:terminal, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp auth_conn(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  setup do
    user = insert(:user)
    {:ok, token, _} = Guardian.encode_and_sign(user)

    book = insert(:book, title: "Test Book")
    insert(:book_edition, book: book, isbn: "9780743273565")

    {:ok, user: user, token: token, book: book}
  end

  # ---------------------------------------------------------------------------
  # 1. :resolved outcome — IdentifyBookJob success
  # ---------------------------------------------------------------------------

  describe "terminal counter — :resolved" do
    test "emits [:stacks, :upload, :terminal] with outcome: :resolved when image resolves",
         %{user: user} do
      attach_terminal_handler()

      image = insert(:uploaded_image, status: "pending", user_id: user.id)

      {:ok, _job} =
        Oban.insert(
          IdentifyBookJob.new(%{
            "user_id" => user.id,
            "image_id" => image.id,
            "image_b64" => @image_b64
          })
        )

      Oban.drain_queue(queue: :vision)

      # The mock vision client resolves to a book in the test env. If not, the
      # telemetry event is still expected for whatever terminal outcome fires.
      # DoD requires that the :resolved transition publishes this event.
      assert_receive {:terminal, %{count: 1}, %{outcome: :resolved}}, 5_000
    end
  end

  # ---------------------------------------------------------------------------
  # 2. :rejected outcome — IdentifyBookJob cancel path
  # ---------------------------------------------------------------------------

  defmodule NotABookClient do
    @moduledoc false
    @behaviour Stacks.AI.ClientBehaviour
    @impl true
    # Returns the consolidated /analyze shape — classification + (empty)
    # books field in one response. Matches what Moderation calls via the
    # single-request /analyze endpoint post-consolidation.
    def call_vision("analyze", _payload),
      do:
        {:ok,
         %{
           "classification" => "CLASSIFICATION_RESULT_NOT_BOOK",
           "confidence" => 0.95,
           "books" => [],
           "model_used" => "mock"
         }}

    def call_vision(_endpoint, _payload), do: {:ok, %{}}
  end

  describe "terminal counter — :rejected" do
    test "emits [:stacks, :upload, :terminal] with outcome: :rejected on not_a_book cancel",
         %{user: user} do
      attach_terminal_handler()

      original_client = Application.get_env(:core, :vision_client)
      Application.put_env(:core, :vision_client, NotABookClient)
      on_exit(fn -> Application.put_env(:core, :vision_client, original_client) end)

      image = insert(:uploaded_image, status: "pending", user_id: user.id)

      {:ok, _job} =
        Oban.insert(
          IdentifyBookJob.new(%{
            "user_id" => user.id,
            "image_id" => image.id,
            "image_b64" => @image_b64
          })
        )

      Oban.drain_queue(queue: :vision)

      assert_receive {:terminal, %{count: 1}, %{outcome: :rejected}}, 5_000
    end
  end

  # ---------------------------------------------------------------------------
  # 3. :timeout outcome — SSE upload stream timeout
  # ---------------------------------------------------------------------------

  describe "terminal counter — :timeout" do
    test "emits [:stacks, :upload, :terminal] with outcome: :timeout when SSE stream times out",
         %{conn: conn, token: token, user: user} do
      attach_terminal_handler()

      # Force a tiny SSE deadline so the stream exits with :timeout quickly.
      original = Application.get_env(:core, :sse_max_timeout_ms, 60_000)
      Application.put_env(:core, :sse_max_timeout_ms, 1)
      on_exit(fn -> Application.put_env(:core, :sse_max_timeout_ms, original) end)

      image = insert(:uploaded_image, status: "pending", user_id: user.id)

      conn
      |> auth_conn(token)
      |> get("/api/upload/#{image.id}/stream?token=#{token}")

      assert_receive {:terminal, %{count: 1}, %{outcome: :timeout}}, 5_000
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Non-terminal transitions must NOT emit this event
  # ---------------------------------------------------------------------------

  describe "terminal counter — non-terminal transitions" do
    test "pending → pending (no status change) does NOT emit [:stacks, :upload, :terminal]",
         %{user: user} do
      attach_terminal_handler()

      _image = insert(:uploaded_image, status: "pending", user_id: user.id)

      # Touching the record without changing to a terminal state must be silent.
      # Give any stray handler some time to fire before asserting absence.
      refute_receive {:terminal, _measurements, _metadata}, 500
    end

    test "inserting a new pending image (no transition to a terminal state) does NOT emit telemetry",
         %{user: user} do
      attach_terminal_handler()

      # Creating an uploaded_image in the `pending` state is NOT a terminal
      # transition. No [:stacks, :upload, :terminal] event should fire.
      _image = insert(:uploaded_image, status: "pending", user_id: user.id)

      refute_receive {:terminal, _measurements, _metadata}, 500
    end

    test "running IdentifyBookJob against an already-resolved image does NOT re-emit telemetry",
         %{user: user, book: book} do
      # Regression for Issue #136 Phase 1 revision cycle 1:
      # `mark_resolved` / `mark_rejected` previously UPDATEd the row
      # unconditionally, which meant an Oban retry that re-entered the
      # success path on an already-resolved row would re-fire the terminal
      # counter. The fix scopes the update to `status = "pending"` so only
      # real pending -> terminal transitions emit the event.
      attach_terminal_handler()

      image =
        insert(:uploaded_image,
          status: "resolved",
          user_id: user.id,
          book_id: book.id,
          book_ids: [book.id]
        )

      {:ok, _job} =
        Oban.insert(
          IdentifyBookJob.new(%{
            "user_id" => user.id,
            "image_id" => image.id,
            "image_b64" => @image_b64
          })
        )

      Oban.drain_queue(queue: :vision)

      # No terminal event — the row was already in a terminal state.
      refute_receive {:terminal, _measurements, _metadata}, 500
    end
  end
end
