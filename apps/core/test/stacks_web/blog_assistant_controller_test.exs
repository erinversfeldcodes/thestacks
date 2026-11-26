defmodule StacksWeb.BlogAssistantControllerTest do
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.Guardian
  alias Stacks.GDPR.Consent
  alias Stacks.WritingAssistant.Embedding

  defp authed(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  # Matches the mock /embed query vector (all 0.5), so retrieval returns it.
  defp seed_chunk(user_id, text) do
    Repo.insert!(%Embedding{
      user_id: user_id,
      source_type: "imported_work",
      source_id: Ecto.UUID.generate(),
      embedding: List.duplicate(0.5, 1024),
      chunk_text: text,
      chunk_index: 0,
      model: "bge-m3",
      embedding_version: 1
    })
  end

  describe "POST /api/blog/posts/:id/chat" do
    test "with writing_assistant consent: streams ack, message, and done", %{conn: conn} do
      user = insert(:user)
      Consent.grant_consent(user.id, "writing_assistant")
      seed_chunk(user.id, "the moors were cold and misty at dawn")

      conn =
        conn
        |> authed(user)
        |> post("/api/blog/posts/#{Ecto.UUID.generate()}/chat", %{
          prompt: "What were the moors like?"
        })

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "text/event-stream"
      assert conn.resp_body =~ "event: ack"
      assert conn.resp_body =~ "event: message"
      assert conn.resp_body =~ "event: done"
    end

    test "WITHOUT writing_assistant consent: 403", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> authed(user)
        |> post("/api/blog/posts/#{Ecto.UUID.generate()}/chat", %{prompt: "hi"})

      assert json_response(conn, 403)
    end
  end
end
