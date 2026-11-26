defmodule StacksWeb.WritingControllerTest do
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory
  import Ecto.Query

  alias Core.Repo
  alias Stacks.Accounts.Guardian
  alias Stacks.GDPR.Consent
  alias Stacks.WritingAssistant.{Corpus, Embedding, ImportedWork}

  @content_b64 Base.encode64("the raw bytes are never persisted")

  defp authed(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "POST /api/writing/import" do
    test "with writing_assistant consent: ingests and returns the work", %{conn: conn} do
      user = insert(:user)
      Consent.grant_consent(user.id, "writing_assistant")

      conn =
        conn
        |> authed(user)
        |> post("/api/writing/import", %{
          title: "Manuscript",
          format: "txt",
          content: @content_b64
        })

      assert %{"work_id" => work_id, "chunks" => chunks} = json_response(conn, 201)
      assert chunks > 0
      assert Repo.get(ImportedWork, work_id)

      assert Repo.aggregate(
               from(e in Embedding,
                 where: e.source_type == "imported_work" and e.source_id == ^work_id
               ),
               :count
             ) > 0
    end

    test "WITHOUT writing_assistant consent: 403, and ingests nothing", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> authed(user)
        |> post("/api/writing/import", %{title: "M", format: "txt", content: @content_b64})

      assert json_response(conn, 403)
      assert Repo.aggregate(ImportedWork, :count) == 0
    end

    test "unsupported format: 422", %{conn: conn} do
      user = insert(:user)
      Consent.grant_consent(user.id, "writing_assistant")

      conn =
        conn
        |> authed(user)
        |> post("/api/writing/import", %{title: "M", format: "rtf", content: @content_b64})

      assert %{"error" => "unsupported_format"} = json_response(conn, 422)
    end
  end

  describe "POST /api/writing/works/:work_id/annotations" do
    test "records a do-not-retrieve annotation on an imported work", %{conn: conn} do
      user = insert(:user)
      Consent.grant_consent(user.id, "writing_assistant")

      # Set the work up through the context so the single CSRF-proof conn the
      # ConnCase seeds is free for the annotation POST (recycling/rebuilding it
      # drops that proof and the CSRF plug 403s — /writing is not path-exempt).
      {:ok, %{work: work}} = Corpus.import_document(user.id, "W", "a draft", "md")

      conn =
        conn
        |> authed(user)
        |> post("/api/writing/works/#{work.id}/annotations", %{
          tags: ["exemplar"],
          do_not_retrieve: true
        })

      assert %{"annotation_id" => _} = json_response(conn, 201)
    end
  end
end
