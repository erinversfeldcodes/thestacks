defmodule Stacks.UploadDbtTest do
  @moduledoc """
  Deployed-only tests that verify dbt staging views materialise correctly
  from `op.uploaded_images` data. These tests query `wh.stg_uploaded_images`
  and related staging views, which only exist after `dbt run`.

  Excluded by default (see test_helper.exs). Run with:

      TEST_TARGET=deployed mix test --only deployed_only
  """

  use Core.DataCase, async: false

  @tag :deployed_only
  test "stg_uploaded_images view exists and is queryable" do
    result = Core.Repo.query("SELECT COUNT(*) FROM wh.stg_uploaded_images")
    assert {:ok, %{rows: [[count]]}} = result
    assert is_integer(count)
  end

  @tag :deployed_only
  test "stg_uploaded_images columns match expected schema" do
    {:ok, %{columns: columns}} =
      Core.Repo.query("SELECT * FROM wh.stg_uploaded_images LIMIT 0")

    expected =
      ~w(id book_id storage_path status rejection_reason uploaded_at expires_at created_at updated_at book_ids book_edition_id)

    assert MapSet.new(expected) == MapSet.new(columns)
  end

  @tag :deployed_only
  test "stg_books view exists and is queryable" do
    result = Core.Repo.query("SELECT COUNT(*) FROM wh.stg_books")
    assert {:ok, %{rows: [[count]]}} = result
    assert is_integer(count)
  end

  @tag :deployed_only
  test "stg_users view exists and is queryable" do
    result = Core.Repo.query("SELECT COUNT(*) FROM wh.stg_users")
    assert {:ok, %{rows: [[count]]}} = result
    assert is_integer(count)
  end

  @tag :deployed_only
  test "stg_uploaded_images status values are valid" do
    {:ok, %{rows: rows}} =
      Core.Repo.query(
        "SELECT DISTINCT status FROM wh.stg_uploaded_images WHERE status IS NOT NULL"
      )

    valid_statuses = MapSet.new(~w(pending resolved rejected))

    for [status] <- rows do
      assert MapSet.member?(valid_statuses, status),
             "Unexpected status in stg_uploaded_images: #{status}"
    end
  end
end
