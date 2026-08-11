defmodule Stacks.UploadTerminalTelemetryTest do
  @moduledoc """
      Upload terminal counter: every `uploaded_image` transition to a
      terminal state must emit `[:stacks,:upload,:terminal]` with
      `outcome::resolved |:rejected |:timeout`; non-terminal transitions
      must not. `IdentifyBookJob` is the canonical path to
      resolved/rejected;:timeout comes from the SSE stream.
  """

  use CoreWeb.ConnCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.AI.VisionFixtures
  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Workers.IdentifyBookJob

  @image_b64 Base.encode64("fake image bytes for testing")

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

      assert_receive {:terminal, %{count: 1}, %{outcome: :resolved}}, 5_000
    end
  end

  describe "terminal counter — :rejected" do
    test "emits [:stacks, :upload, :terminal] with outcome: :rejected on not_a_book cancel",
         %{user: user} do
      attach_terminal_handler()

      steer_vision(not_a_book())

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

  describe "terminal counter — :timeout" do
    test "emits [:stacks, :upload, :terminal] with outcome: :timeout when SSE stream times out",
         %{conn: conn, token: token, user: user} do
      attach_terminal_handler()

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

  describe "terminal counter — non-terminal transitions" do
    test "pending → pending (no status change) does NOT emit [:stacks, :upload, :terminal]",
         %{user: user} do
      attach_terminal_handler()

      _image = insert(:uploaded_image, status: "pending", user_id: user.id)

      refute_receive {:terminal, _measurements, _metadata}, 500
    end

    test "inserting a new pending image (no transition to a terminal state) does NOT emit telemetry",
         %{user: user} do
      attach_terminal_handler()

      _image = insert(:uploaded_image, status: "pending", user_id: user.id)

      refute_receive {:terminal, _measurements, _metadata}, 500
    end

    test "running IdentifyBookJob against an already-resolved image does NOT re-emit telemetry",
         %{user: user, book: book} do
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

      refute_receive {:terminal, _measurements, _metadata}, 500
    end
  end
end
