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
    test "an uploaded object is gone from the backend afterwards" do
      {:ok, key} = Storage.upload_image(Ecto.UUID.generate(), "data")

      assert {:ok, _bytes} = Storage.head_image(key),
             "the object was never there, so its absence below would prove nothing"

      assert :ok = Storage.delete_image(key)
      assert {:error, :not_found} = Storage.head_image(key)
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

  describe "list_objects/1" do
    test "returns only the keys under the prefix" do
      Mock.seed("exports/alice/1-a.json", "{}")
      Mock.seed("exports/bob/2-b.json", "{}")
      Mock.seed("uploads/an-image", "bytes")

      assert {:ok, ["exports/alice/1-a.json"]} = Storage.list_objects("exports/alice/")
      assert {:ok, keys} = Storage.list_objects("exports/")
      assert Enum.sort(keys) == ["exports/alice/1-a.json", "exports/bob/2-b.json"]
    end
  end
end

defmodule Stacks.Storage.LocalTest do
  @moduledoc """
      Filesystem-backend tests. The dev backend is the one place a GDPR export
      could be served to the world by accident: `priv/static/uploads` is handed
      to `Plug.Static`, so an export written there would be a public URL away
      from anyone who guessed it. These pin the separation and the listing the
      retention sweep depends on.
  """

  use ExUnit.Case, async: false

  alias Stacks.Storage.Local

  setup do
    base = Path.join(System.tmp_dir!(), "stacks-local-#{System.unique_integer([:positive])}")
    uploads = Path.join(base, "static/uploads")
    exports = Path.join(base, "exports")

    Application.put_env(:core, :upload_dir, uploads)
    Application.put_env(:core, :export_dir, exports)

    on_exit(fn ->
      Application.delete_env(:core, :upload_dir)
      Application.delete_env(:core, :export_dir)
      File.rm_rf(base)
    end)

    {:ok, uploads: uploads, exports: exports}
  end

  test "an export is written outside the statically served upload directory", ctx do
    assert {:ok, key} = Local.put("exports/alice/1-a.json", "{}")
    assert {:ok, _size} = Local.head(key)

    assert File.exists?(Path.join(ctx.exports, key))
    refute File.exists?(Path.join(ctx.uploads, key))
  end

  test "listing finds nested export keys and leaves uploads alone", ctx do
    {:ok, _} = Local.put("exports/alice/1-a.json", "{}")
    {:ok, _} = Local.put("exports/bob/2-b.json", "{}")
    {:ok, _} = Local.put("uploads/an-image", "bytes")

    assert {:ok, keys} = Local.list("exports/")
    assert Enum.sort(keys) == ["exports/alice/1-a.json", "exports/bob/2-b.json"]

    assert {:ok, ["exports/alice/1-a.json"]} = Local.list("exports/alice/")
    assert File.exists?(Path.join(ctx.uploads, "uploads/an-image"))
  end

  test "a deleted export is gone from the listing" do
    {:ok, key} = Local.put("exports/alice/1-a.json", "{}")

    assert :ok = Local.delete(key)
    assert {:ok, []} = Local.list("exports/")
  end
end
