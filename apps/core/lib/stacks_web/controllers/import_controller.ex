defmodule StacksWeb.ImportController do
  @moduledoc """
  Goodreads library import (US-1.1.9).

  `POST /api/imports/goodreads` takes the export CSV as a multipart `file`,
  parses it synchronously — so "this isn't a Goodreads export" is a 422 at
  upload time, not a failed job discovered later — and answers 202 with the
  created import; `Stacks.Workers.GoodreadsImportJob` does the shelving.
  One import at a time per user (409). The reads are the reader's own progress
  and per-row report, always owner-scoped.
  """

  use CoreWeb, :controller

  alias Stacks.Accounts.Guardian
  alias Stacks.Imports

  # Well past any real Goodreads export (thousands of books ≈ single-digit MB)
  # while keeping a runaway upload from being read into memory whole.
  @max_bytes 10 * 1024 * 1024

  @doc "POST /api/imports/goodreads"
  def create(conn, %{"file" => %Plug.Upload{} = upload}) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, %{size: size}} when size <= @max_bytes <- File.stat(upload.path),
         {:ok, binary} <- File.read(upload.path) do
      case Imports.create_import(user.id, upload.filename, binary) do
        {:ok, import} ->
          conn
          |> put_status(202)
          |> json(%{import: import_json(import)})

        {:error, :import_in_progress} ->
          conn
          |> put_status(409)
          |> json(%{error: "import_in_progress"})

        {:error, :no_rows} ->
          conn
          |> put_status(422)
          |> json(%{error: "no_rows"})

        {:error, :unrecognised_format, headers} ->
          conn
          |> put_status(422)
          |> json(%{error: "unrecognised_format", found_headers: headers})
      end
    else
      {:ok, %{size: _too_big}} ->
        conn |> put_status(413) |> json(%{error: "file_too_large", max_bytes: @max_bytes})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: "unreadable_upload: #{reason}"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "missing_file", detail: "attach the CSV as multipart field \"file\""})
  end

  @doc "GET /api/imports"
  def index(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    json(conn, %{imports: user.id |> Imports.list_imports() |> Enum.map(&import_json/1)})
  end

  @doc "GET /api/imports/:id"
  def show(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    case Imports.get_import(user.id, id) do
      nil -> conn |> put_status(404) |> json(%{error: "not_found"})
      import -> json(conn, %{import: import_json(import)})
    end
  end

  @doc "GET /api/imports/:id/rows — optional ?outcome=unverified filter"
  def rows(conn, %{"id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)
    opts = if outcome = params["outcome"], do: [outcome: outcome], else: []

    case Imports.list_rows(user.id, id, opts) do
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:ok, rows} ->
        json(conn, %{rows: Enum.map(rows, &row_json/1)})
    end
  end

  defp import_json(import) do
    %{
      id: import.id,
      source: import.source,
      filename: import.filename,
      status: import.status,
      row_count: import.row_count,
      processed_count: import.processed_count,
      shelved_count: import.shelved_count,
      duplicate_count: import.duplicate_count,
      unverified_count: import.unverified_count,
      unreadable_count: import.unreadable_count,
      created_at: DateTime.to_iso8601(import.created_at),
      finished_at: import.finished_at && DateTime.to_iso8601(import.finished_at)
    }
  end

  defp row_json(row) do
    %{
      row_number: row.row_number,
      title: row.raw_title,
      author: row.raw_author,
      isbn13: row.raw_isbn13,
      goodreads_shelf: row.goodreads_shelf,
      outcome: row.outcome,
      reason: row.reason,
      book_id: row.book_id
    }
  end
end
