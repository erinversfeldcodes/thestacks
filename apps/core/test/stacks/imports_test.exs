defmodule Stacks.ImportsTest do
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Stacks.Events.EventLog
  alias Stacks.Imports
  alias Stacks.Imports.LibraryImportRow
  alias Stacks.Workers.GoodreadsImportJob

  @fixture Path.expand("../support/fixtures/goodreads_library_export.csv", __DIR__)

  defp fixture_csv, do: File.read!(@fixture)

  describe "create_import/3" do
    test "persists the import with its rows and enqueues the first batch" do
      user = insert(:user)

      assert {:ok, import} =
               Imports.create_import(user.id, "goodreads_library_export.csv", fixture_csv())

      assert import.status == "enqueued"
      assert import.source == "goodreads"
      assert import.row_count == 5

      rows = Repo.all(from r in LibraryImportRow, where: r.import_id == ^import.id)
      assert length(rows) == 5
      assert Enum.all?(rows, &is_nil(&1.outcome))

      assert_enqueued(
        worker: GoodreadsImportJob,
        args: %{"import_id" => import.id, "offset" => 0}
      )
    end

    test "emits library_import.started with counts only — never row content" do
      user = insert(:user)
      {:ok, import} = Imports.create_import(user.id, "export.csv", fixture_csv())

      event =
        Repo.one!(
          from e in EventLog,
            where: e.event_type == "library_import.started" and e.aggregate_id == ^import.id
        )

      assert event.payload["row_count"] == 5
      refute Map.has_key?(event.payload, "rows")
      refute inspect(event.payload) =~ "Lent to Sam"
    end

    test "refuses a second import while one is active" do
      user = insert(:user)
      {:ok, _} = Imports.create_import(user.id, "first.csv", fixture_csv())

      assert {:error, :import_in_progress} =
               Imports.create_import(user.id, "second.csv", fixture_csv())
    end

    test "a finished import does not block the next one" do
      user = insert(:user)
      {:ok, import} = Imports.create_import(user.id, "first.csv", fixture_csv())
      {:ok, _} = Imports.finalize(import, "complete")

      assert {:ok, _} = Imports.create_import(user.id, "second.csv", fixture_csv())
    end

    test "another user's active import does not block mine" do
      other = insert(:user)
      {:ok, _} = Imports.create_import(other.id, "theirs.csv", fixture_csv())

      user = insert(:user)
      assert {:ok, _} = Imports.create_import(user.id, "mine.csv", fixture_csv())
    end

    test "rejects a non-Goodreads file at upload time" do
      user = insert(:user)

      assert {:error, :unrecognised_format, _headers} =
               Imports.create_import(user.id, "random.csv", "a,b\n1,2\n")

      assert Imports.list_imports(user.id) == []
    end
  end

  describe "scoped reads" do
    test "get_import/2 and list_rows/3 are owner-scoped" do
      owner = insert(:user)
      stranger = insert(:user)
      {:ok, import} = Imports.create_import(owner.id, "export.csv", fixture_csv())

      assert Imports.get_import(owner.id, import.id)
      refute Imports.get_import(stranger.id, import.id)
      assert {:error, :not_found} = Imports.list_rows(stranger.id, import.id)
    end

    test "list_rows/3 filters by outcome" do
      user = insert(:user)
      {:ok, import} = Imports.create_import(user.id, "export.csv", fixture_csv())

      {:ok, [first | _]} = Imports.list_rows(user.id, import.id)
      Imports.record_outcome(first, "unverified", reason: "test")

      assert {:ok, [reported]} = Imports.list_rows(user.id, import.id, outcome: "unverified")
      assert reported.row_number == first.row_number
    end
  end

  describe "finalize/2" do
    test "aggregates counts from row outcomes and emits the completed event" do
      user = insert(:user)
      {:ok, import} = Imports.create_import(user.id, "export.csv", fixture_csv())
      {:ok, rows} = Imports.list_rows(user.id, import.id)

      [a, b, c, d, e] = rows
      Imports.record_outcome(a, "shelved")
      Imports.record_outcome(b, "shelved")
      Imports.record_outcome(c, "duplicate")
      Imports.record_outcome(d, "unverified", reason: "no ISBN")
      Imports.record_outcome(e, "unreadable", reason: "bad row")

      assert {:ok, bookshelves} = Imports.finalize(import, "complete")

      import = Imports.get_import(user.id, import.id)
      assert import.status == "complete"
      assert import.finished_at
      assert import.processed_count == 5
      assert import.shelved_count == 2
      assert import.duplicate_count == 1
      assert import.unverified_count == 1
      assert import.unreadable_count == 1

      # Rows 1 (read) and 2 (currently-reading) were marked shelved above.
      assert Enum.sort(bookshelves) == ["library", "reading_pile"]

      event =
        Repo.one!(
          from e in EventLog,
            where: e.event_type == "library_import.completed" and e.aggregate_id == ^import.id
        )

      assert event.payload["shelved_count"] == 2
      assert event.payload["status"] == "complete"
    end
  end

  describe "delete_expired_rows/0 (30-day retention)" do
    test "deletes rows past retention, keeps the import summary" do
      user = insert(:user)
      {:ok, import} = Imports.create_import(user.id, "export.csv", fixture_csv())

      stale = DateTime.add(DateTime.utc_now(), -31, :day)

      Repo.update_all(from(r in LibraryImportRow, where: r.import_id == ^import.id),
        set: [created_at: stale]
      )

      assert Imports.delete_expired_rows() == 5
      assert {:ok, []} = Imports.list_rows(user.id, import.id)
      assert Imports.get_import(user.id, import.id).row_count == 5
    end

    test "leaves rows inside the window alone" do
      user = insert(:user)
      {:ok, import} = Imports.create_import(user.id, "export.csv", fixture_csv())

      assert Imports.delete_expired_rows() == 0
      assert {:ok, rows} = Imports.list_rows(user.id, import.id)
      assert length(rows) == 5
    end
  end
end
