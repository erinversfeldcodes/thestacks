defmodule StacksWeb.ImportControllerTest do
  @moduledoc "Tests for the Goodreads import endpoints."

  use CoreWeb.ConnCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Imports
  alias Stacks.Workers.GoodreadsImportJob

  @fixture Path.expand("../support/fixtures/goodreads_library_export.csv", __DIR__)

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp upload_fixture(filename \\ "goodreads_library_export.csv") do
    %Plug.Upload{
      path: @fixture,
      filename: filename,
      content_type: "text/csv"
    }
  end

  defp csv_upload(content) do
    path = Path.join(System.tmp_dir!(), "import-test-#{System.unique_integer([:positive])}.csv")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: "export.csv", content_type: "text/csv"}
  end

  describe "POST /api/imports/goodreads" do
    test "accepts a Goodreads export: 202, import persisted, job enqueued", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/imports/goodreads", %{"file" => upload_fixture()})

      assert %{"import" => import_json} = json_response(conn, 202)
      assert import_json["status"] == "enqueued"
      assert import_json["row_count"] == 5
      assert import_json["filename"] == "goodreads_library_export.csv"

      assert_enqueued(
        worker: GoodreadsImportJob,
        args: %{"import_id" => import_json["id"], "offset" => 0}
      )
    end

    test "a non-Goodreads CSV is a 422 at upload time", %{conn: conn} do
      user = insert(:user)
      upload = csv_upload("name,number\nAlice,42\n")

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/imports/goodreads", %{"file" => upload})

      assert %{"error" => "unrecognised_format", "found_headers" => headers} =
               json_response(conn, 422)

      assert "name" in headers
    end

    test "a second concurrent import is a 409", %{conn: conn} do
      user = insert(:user)
      {:ok, _} = Imports.create_import(user.id, "first.csv", File.read!(@fixture))

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/imports/goodreads", %{"file" => upload_fixture()})

      assert %{"error" => "import_in_progress"} = json_response(conn, 409)
    end

    test "a missing file is a 422 with a usable hint", %{conn: conn} do
      user = insert(:user)
      conn = conn |> auth_conn(user) |> post("/api/imports/goodreads", %{})

      assert %{"error" => "missing_file"} = json_response(conn, 422)
    end

    test "unauthenticated is a 401", %{conn: conn} do
      conn = post(conn, "/api/imports/goodreads", %{"file" => upload_fixture()})
      assert conn.status == 401
    end
  end

  describe "the reads" do
    setup %{conn: conn} do
      user = insert(:user)
      {:ok, import} = Imports.create_import(user.id, "export.csv", File.read!(@fixture))
      %{conn: auth_conn(conn, user), user: user, import: import}
    end

    test "GET /api/imports lists mine, newest first", %{conn: conn, import: import} do
      assert %{"imports" => [listed]} = json_response(get(conn, "/api/imports"), 200)
      assert listed["id"] == import.id
    end

    test "GET /api/imports/:id shows progress counts", %{conn: conn, import: import} do
      assert %{"import" => shown} = json_response(get(conn, "/api/imports/#{import.id}"), 200)
      assert shown["row_count"] == 5
      assert shown["processed_count"] == 0
    end

    test "GET /api/imports/:id/rows returns the per-row report with outcome filter", %{
      conn: conn,
      user: user,
      import: import
    } do
      {:ok, [first | _]} = Imports.list_rows(user.id, import.id)
      Imports.record_outcome(first, "unverified", reason: "no ISBN")

      assert %{"rows" => rows} = json_response(get(conn, "/api/imports/#{import.id}/rows"), 200)
      assert length(rows) == 5

      assert %{"rows" => [reported]} =
               json_response(get(conn, "/api/imports/#{import.id}/rows?outcome=unverified"), 200)

      assert reported["row_number"] == 1
      assert reported["reason"] == "no ISBN"
    end

    test "a misspelled outcome is refused, not answered with an empty report", %{
      conn: conn,
      user: user,
      import: import
    } do
      # The filter is applied by string equality, so an unknown value matched
      # nothing and the endpoint answered `200 {"rows": []}` — identical to the
      # true statement "nothing in this import was shelved". A client reading
      # that cannot tell which it got, and the mistake is a single character.
      {:ok, [first | _]} = Imports.list_rows(user.id, import.id)
      Imports.record_outcome(first, "shelved")

      body = json_response(get(conn, "/api/imports/#{import.id}/rows?outcome=shelve"), 422)

      assert body["error"] == "unknown_outcome"

      assert Enum.sort(body["valid_outcomes"]) ==
               Enum.sort(["shelved", "duplicate", "unverified", "unreadable"])

      # And the near-miss really would have come back empty, so the refusal is
      # carrying information the 200 could not. Without this the test above
      # passes against an endpoint that refuses everything.
      assert %{"rows" => [_]} =
               json_response(get(conn, "/api/imports/#{import.id}/rows?outcome=shelved"), 200)
    end

    test "another user's import is a 404, not a leak", %{conn: _conn, import: import} do
      stranger = insert(:user)
      conn = auth_conn(Phoenix.ConnTest.build_conn(), stranger)

      assert json_response(get(conn, "/api/imports/#{import.id}"), 404)
      assert json_response(get(conn, "/api/imports/#{import.id}/rows"), 404)
    end

    test "an import with no filename answers a blank one, not a null", %{
      conn: conn,
      import: import
    } do
      # `op.library_imports.filename` is nullable and the client's decoder
      # requires a string, so a null would fail the decode and take the whole
      # import page — the same shape that made one unreadable CSV row render
      # "the report didn't load" forever.
      import |> Ecto.Changeset.change(filename: nil) |> Core.Repo.update!()

      assert %{"import" => shown} = json_response(get(conn, "/api/imports/#{import.id}"), 200)
      assert shown["filename"] == ""
    end
  end
end
