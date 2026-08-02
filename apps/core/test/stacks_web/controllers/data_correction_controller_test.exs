defmodule StacksWeb.DataCorrectionControllerTest do
  @moduledoc """
  Issue #340 — the owner-facing surface of `Stacks.DataCorrection`.

  Four properties are load-bearing, and each has a test written to fail if the
  property goes away rather than to describe the code:

    * **owner-only, checked where the write happens.** `403 for a non-owner
      holding a valid MFA-verified admin session` fails the moment
      `:require_owner` leaves the route. The admin login already refuses a
      non-owner, so a test that only exercised login would still pass with the
      route wide open.
    * **dry-run is what a GET means.** `index` reports the blast radius and the
      row is asserted unchanged afterwards.
    * **idempotent.** Applying twice: the second call reports zero rows and
      writes no further audit rows.
    * **audited in the change's transaction**, with the operator and their
      reason — asserted on the row, not on the response.
  """
  use CoreWeb.ConnCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext
  alias Stacks.Books.BookEdition

  @constraint "book_editions_isbn_ean13_checksum"

  # The ISBN-10 the Wave 4 live drive found in production, verbatim.
  @isbn10 "0071615695"
  @isbn13 "9780071615693"

  # ── Session helpers ───────────────────────────────────────────────────────

  # An MFA-verified admin session for `user`, minted directly rather than
  # through `POST /api/admin/auth/login`. That is deliberate: login refuses a
  # non-owner, so going through it could never produce the token a demoted
  # operator still holds — which is exactly the case `:require_owner` exists for.
  defp admin_session(conn, user) do
    boot_id = Core.Application.boot_id()
    {:ok, session} = SessionContext.create(user, "127.0.0.1", boot_id)
    {:ok, session} = SessionContext.mark_mfa_verified(session)

    {:ok, token, _} =
      Guardian.encode_and_sign(user, %{},
        token_type: "admin",
        session_id: session.id,
        boot_id: boot_id,
        ttl: {30, :minute}
      )

    {put_req_header(conn, "authorization", "Bearer #{token}"), session}
  end

  defp as_owner(conn) do
    user = insert(:owner_user)
    {conn, _session} = admin_session(conn, user)
    {conn, user}
  end

  # ── Data helpers ──────────────────────────────────────────────────────────

  defp constraint_definition do
    %{rows: [[definition]]} =
      Repo.query!("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1", [
        @constraint
      ])

    definition
  end

  # Writes a row the current constraint forbids, the way a pre-2026-05-15 write
  # path did: no changeset, no normalisation.
  defp plant_legacy_edition!(isbn) do
    book = insert(:editionless_book)
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO op.book_editions
        (id, book_id, isbn, is_primary, verification_source, created_at, updated_at)
      VALUES ($1, $2, $3, true, 'barcode_unverified', now(), now())
      """,
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(book.id), isbn]
    )

    id
  end

  defp isbn_of(id), do: Repo.one(from(e in BookEdition, where: e.id == ^id, select: e.isbn))

  defp correction_audit_rows do
    %{rows: rows} =
      Repo.query!(
        "SELECT resource_id, user_id, metadata FROM audit.audit_log WHERE action = 'data.correction.applied'"
      )

    Enum.map(rows, fn [resource_id, user_id, metadata] ->
      {:ok, json} = Stacks.Vault.decrypt(metadata)
      {Ecto.UUID.load!(resource_id), user_id && Ecto.UUID.load!(user_id), Jason.decode!(json)}
    end)
  end

  setup do
    definition = constraint_definition()
    Repo.query!("ALTER TABLE op.book_editions DROP CONSTRAINT #{@constraint}")
    id = plant_legacy_edition!(@isbn10)
    %{definition: definition, id: id}
  end

  # ── Authorisation ─────────────────────────────────────────────────────────

  describe "authorisation" do
    test "GET is 401 without an admin token", %{conn: conn} do
      assert json_response(get(conn, "/api/admin/data_corrections"), 401)
    end

    test "POST is 401 without an admin token", %{conn: conn} do
      conn = post(conn, "/api/admin/data_corrections/normalise_edition_isbn10/apply", %{})
      assert json_response(conn, 401)
    end

    test "GET is 403 for a non-owner holding a valid MFA-verified admin session", %{conn: conn} do
      {conn, _session} = admin_session(conn, insert(:user))

      assert json_response(get(conn, "/api/admin/data_corrections"), 403)
    end

    test "POST is 403 for a non-owner, and changes nothing", %{conn: conn, id: id} do
      {conn, _session} = admin_session(conn, insert(:user))

      conn =
        post(conn, "/api/admin/data_corrections/normalise_edition_isbn10/apply", %{
          reason: "I should not be able to do this"
        })

      assert json_response(conn, 403)
      assert isbn_of(id) == @isbn10
      assert correction_audit_rows() == []
    end
  end

  # ── Dry run ───────────────────────────────────────────────────────────────

  describe "GET /api/admin/data_corrections" do
    test "lists every registered correction with its scope and reversibility", %{conn: conn} do
      {conn, _owner} = as_owner(conn)

      assert %{"corrections" => corrections} =
               json_response(get(conn, "/api/admin/data_corrections"), 200)

      assert Enum.map(corrections, & &1["name"]) == [
               "normalise_edition_isbn10",
               "stale_seed_edition_isbn"
             ]

      for correction <- corrections do
        assert correction["reversibility"] in ["one_way", "reversible"]
        assert correction["reversibility_note"] != ""
        assert correction["scope"] != ""
        assert correction["mode"] == "dry_run"
      end
    end

    test "reports the blast radius — which row, from what, to what and why", %{
      conn: conn,
      id: id
    } do
      {conn, _owner} = as_owner(conn)

      %{"corrections" => corrections} =
        json_response(get(conn, "/api/admin/data_corrections"), 200)

      correction = Enum.find(corrections, &(&1["name"] == "normalise_edition_isbn10"))

      assert correction["count"] == 1

      assert [%{"id" => ^id, "from" => @isbn10, "to" => @isbn13, "because" => because}] =
               correction["changes"]

      assert because =~ "unnormalised"
    end

    test "writes nothing — a GET is a dry run, not a mode you opt into", %{conn: conn, id: id} do
      {conn, _owner} = as_owner(conn)

      get(conn, "/api/admin/data_corrections")

      assert isbn_of(id) == @isbn10
      assert correction_audit_rows() == []
    end
  end

  # ── Applying ──────────────────────────────────────────────────────────────

  describe "POST /api/admin/data_corrections/:name/apply" do
    test "applies the named correction and reports what it did", %{conn: conn, id: id} do
      {conn, _owner} = as_owner(conn)

      conn =
        post(conn, "/api/admin/data_corrections/normalise_edition_isbn10/apply", %{
          reason: "a reader could not find the book by its barcode"
        })

      assert %{"correction" => correction} = json_response(conn, 200)
      assert correction["mode"] == "applied"
      assert correction["count"] == 1
      assert isbn_of(id) == @isbn13
    end

    test "is idempotent — the second apply changes nothing and audits nothing further", %{
      conn: conn,
      id: id
    } do
      {conn, _owner} = as_owner(conn)
      reason = %{reason: "repairing the legacy ISBN-10s"}

      first =
        post(conn, "/api/admin/data_corrections/normalise_edition_isbn10/apply", reason)

      assert %{"correction" => %{"count" => 1}} = json_response(first, 200)
      assert length(correction_audit_rows()) == 1

      second =
        post(conn, "/api/admin/data_corrections/normalise_edition_isbn10/apply", reason)

      assert %{"correction" => %{"count" => 0, "changes" => []}} = json_response(second, 200)
      assert length(correction_audit_rows()) == 1
      assert isbn_of(id) == @isbn13
    end

    test "audits the operator, their reason and the values, in the change's transaction", %{
      conn: conn,
      id: id
    } do
      {conn, owner} = as_owner(conn)

      post(conn, "/api/admin/data_corrections/normalise_edition_isbn10/apply", %{
        reason: "escalated by the reader on 2026-08-02"
      })

      assert [{^id, actor_id, metadata}] = correction_audit_rows()
      assert actor_id == owner.id
      assert metadata["reason"] =~ "escalated by the reader"
      assert metadata["invoked_by"] == "admin api"
      assert metadata["from"] == @isbn10
      assert metadata["to"] == @isbn13
      assert metadata["correction"] == "normalise_edition_isbn10"
    end

    test "also writes the admin.call row every break-glass endpoint writes", %{conn: conn} do
      {conn, owner} = as_owner(conn)

      post(conn, "/api/admin/data_corrections/normalise_edition_isbn10/apply", %{
        reason: "escalated by the reader"
      })

      %{rows: rows} =
        Repo.query!(
          "SELECT endpoint, row_count, success, user_id FROM audit.audit_log WHERE action = 'admin.call'"
        )

      assert [[endpoint, row_count, true, user_id]] = rows
      assert endpoint == "/api/admin/data_corrections/normalise_edition_isbn10/apply"
      assert row_count == 1
      assert Ecto.UUID.load!(user_id) == owner.id
    end

    test "refuses without a reason, and changes nothing", %{conn: conn, id: id} do
      {conn, _owner} = as_owner(conn)

      for body <- [%{}, %{reason: ""}, %{reason: "   "}] do
        response =
          post(conn, "/api/admin/data_corrections/normalise_edition_isbn10/apply", body)

        assert %{"error" => "reason_required"} = json_response(response, 422)
      end

      assert isbn_of(id) == @isbn10
      assert correction_audit_rows() == []
    end

    test "an unregistered name reaches nothing", %{conn: conn, id: id} do
      {conn, _owner} = as_owner(conn)

      conn =
        post(conn, "/api/admin/data_corrections/delete_every_edition/apply", %{
          reason: "trying it on"
        })

      assert %{"error" => "unknown_correction"} = json_response(conn, 404)
      assert isbn_of(id) == @isbn10
    end

    test "surfaces a collision with real data instead of forcing the write", %{conn: conn, id: id} do
      {conn, _owner} = as_owner(conn)

      # A different edition already owns the ISBN-13 the repair would produce.
      book = insert(:book)
      Repo.insert!(build(:book_edition, book: book, isbn: @isbn13))

      conn =
        post(conn, "/api/admin/data_corrections/normalise_edition_isbn10/apply", %{
          reason: "repairing the legacy ISBN-10s"
        })

      assert %{"error" => "correction_failed", "detail" => detail} = json_response(conn, 422)
      assert detail =~ "isbn_already_present"

      assert isbn_of(id) == @isbn10
      assert correction_audit_rows() == []
    end
  end
end
