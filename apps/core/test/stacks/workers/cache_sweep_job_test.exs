defmodule Stacks.Workers.CacheSweepJobTest do
  use Core.DataCase, async: false

  alias Stacks.Books.IsbnResolverCacheEntry
  alias Stacks.Books.TitleSearchCacheEntry
  alias Stacks.Workers.CacheSweepJob

  test "deletes only expired rows from both cache tables" do
    now = DateTime.utc_now()
    past = DateTime.add(now, -60, :second)
    future = DateTime.add(now, 3600, :second)

    Repo.insert_all(IsbnResolverCacheEntry, [
      %{
        isbn: "9780000000001",
        outcome: "found",
        metadata: %{},
        expires_at: past,
        created_at: now,
        updated_at: now
      },
      %{
        isbn: "9780000000002",
        outcome: "found",
        metadata: %{},
        expires_at: future,
        created_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all(TitleSearchCacheEntry, [
      %{
        cache_key: "expired\x1f\x1f",
        title: "expired",
        author: "",
        raw_text: "",
        outcome: "not_found",
        isbn: "",
        metadata: nil,
        expires_at: past,
        created_at: now,
        updated_at: now
      },
      %{
        cache_key: "fresh\x1f\x1f",
        title: "fresh",
        author: "",
        raw_text: "",
        outcome: "found",
        isbn: "9780000000003",
        metadata: %{},
        expires_at: future,
        created_at: now,
        updated_at: now
      }
    ])

    assert :ok = perform_job(CacheSweepJob, %{})

    assert [isbn_row] = Repo.all(IsbnResolverCacheEntry)
    assert isbn_row.isbn == "9780000000002"

    assert [title_row] = Repo.all(TitleSearchCacheEntry)
    assert title_row.cache_key == "fresh\x1f\x1f"
  end

  defp perform_job(worker, args) do
    Oban.Job.new(args, worker: Atom.to_string(worker)) |> worker.perform()
  end
end
