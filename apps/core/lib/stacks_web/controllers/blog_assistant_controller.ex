defmodule StacksWeb.BlogAssistantController do
  @moduledoc """
      The reader-facing chat seam: the author, editing a post, asks the writing
      assistant for help, grounded in their own corpus.

      Consent-gated on `writing_assistant`, and the response is produced by
      `Stacks.WritingAssistant.Assistant.respond/3`, which refuses to serve
      unless its preconditions are present. The reply is SSE-streamed: an `ack`
      event first (the upload stream's ack-first pattern), then the gated
      response, then `done`. The stream carries the FINAL, gated response rather
      than raw tokens — the never-verbatim and faithfulness checks need the whole
      answer, so there is nothing safe to stream before it exists.
  """
  use CoreWeb, :controller

  alias Core.Repo
  alias Stacks.Accounts.Guardian
  alias Stacks.AI.TogetherClient
  alias Stacks.WritingAssistant.{Assistant, Session}

  plug StacksWeb.Plugs.ConsentCheck, feature: "writing_assistant"

  def chat(conn, %{"id" => post_id, "prompt" => prompt}) when is_binary(prompt) do
    user = Guardian.Plug.current_resource(conn)
    ensure_session(user.id, post_id)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)
      |> sse("ack", %{"post_id" => post_id})

    case Assistant.respond(user.id, prompt) do
      {:ok, result} ->
        conn
        |> sse("message", message_event(result))
        |> sse("done", %{})

      {:error, reason} ->
        sse(conn, "error", %{"reason" => reason_string(reason)})
    end
  end

  def chat(conn, _params) do
    conn |> put_status(400) |> json(%{error: "a string `prompt` is required"})
  end

  defp message_event(result) do
    %{
      "response" => result.response,
      "spans" => length(result.spans),
      "refused" => result[:refused],
      "grounded" => result[:grounded]
    }
  end

  defp sse(conn, event, data) do
    {:ok, conn} = chunk(conn, "event: #{event}\ndata: #{Jason.encode!(data)}\n\n")
    conn
  end

  # One active session per author; its topic records which post the exchange was
  # opened from. The schema carries no turn text, so no corpus text is persisted
  # here — the turns live only in the stream.
  defp ensure_session(user_id, post_id) do
    case Repo.get_by(Session, user_id: user_id, status: "active") do
      nil ->
        Repo.insert!(%Session{
          user_id: user_id,
          status: "active",
          topic: "post:#{post_id}",
          model: TogetherClient.model(),
          started_at: DateTime.utc_now()
        })

      session ->
        session
    end
  end

  defp reason_string({:budget_exceeded, limit}), do: "budget_exceeded:#{limit}"
  defp reason_string(reason), do: to_string(reason)
end
