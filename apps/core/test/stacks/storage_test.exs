defmodule Stacks.StorageTest do
  @moduledoc """
  Tests for the Stacks.Storage context module.

  Uses Stacks.Storage.Mock (configured in test.exs) so tests are isolated
  per process and can run with `async: true`.
  """

  use ExUnit.Case, async: true

  alias Stacks.Storage
  alias Stacks.Storage.Mock

  setup do
    Mock.clear()
    :ok
  end

  describe "upload_image/3" do
    test "stores data and returns {:ok, key}" do
      image_id = Ecto.UUID.generate()
      data = "fake image bytes"

      assert {:ok, key} = Storage.upload_image(image_id, data)
      assert key == "uploads/#{image_id}"
      assert Mock.get(key) == data
    end
  end

  describe "get_image_url/2" do
    test "returns {:ok, url} with a mock presigned URL" do
      key = "uploads/some-id"
      assert {:ok, url} = Storage.get_image_url(key)
      assert url =~ "mock-storage.test"
      assert url =~ key
    end
  end

  describe "delete_image/1" do
    test "removes data from mock storage" do
      key = "uploads/delete-me"
      Mock.seed(key, "data")
      assert Mock.get(key) == "data"

      assert :ok = Storage.delete_image(key)
      assert Mock.get(key) == nil
    end

    test "returns :ok even when key does not exist" do
      assert :ok = Storage.delete_image("uploads/nonexistent")
    end
  end

  describe "store_cover/3" do
    test "stores cover with isbn-based key" do
      isbn = "9780743273565"
      data = "cover image bytes"

      assert {:ok, key} = Storage.store_cover(isbn, data)
      assert key == "covers/#{isbn}-cover.jpg"
      assert Mock.get(key) == data
    end
  end
end
