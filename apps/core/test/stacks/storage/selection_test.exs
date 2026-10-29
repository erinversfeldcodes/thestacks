defmodule Stacks.Storage.SelectionTest do
  use ExUnit.Case, async: true

  alias Stacks.Storage.Selection

  @creds %{
    "R2_ACCOUNT_ID" => "acct",
    "R2_ACCESS_KEY_ID" => "key",
    "R2_SECRET_ACCESS_KEY" => "secret",
    "R2_BUCKET_NAME" => "a-bucket"
  }

  describe "a developer machine" do
    test "gets local storage when it declares nothing" do
      assert {:ok, {:local, _}} = Selection.choose(%{}, false)
    end

    test "STILL gets local storage when credentials are lying around" do
      # ⛔ THE REGRESSION TEST FOR THE DEFECT THIS MODULE WAS EXTRACTED FOR.
      # `config/runtime.exs` read credential presence as intent, so every
      # developer machine with `.env` populated operated on the shared bucket —
      # reads, writes and deletes. A credential is not a request.
      assert {:ok, {:local, _}} = Selection.choose(@creds, false)
    end

    test "can opt in deliberately, and then gets every setting" do
      assert {:ok, {:r2, opts}} =
               Selection.choose(Map.put(@creds, "STORAGE_BACKEND", "r2"), false)

      assert opts[:account_id] == "acct"
      assert opts[:bucket] == "a-bucket"
      assert opts[:access_key_id] == "key"
      assert opts[:secret_access_key] == "secret"
    end

    test "needs no UPLOAD_DIR — the in-repo default is right off a deployment" do
      assert {:ok, {:local, opts}} = Selection.choose(%{}, false)
      assert opts[:upload_dir] == nil
    end
  end

  describe "a deployed build" do
    test "defaults to R2 when the credentials are there" do
      assert {:ok, {:r2, _}} = Selection.choose(@creds, true)
    end

    test "REFUSES TO BOOT rather than silently writing to a container disk" do
      # ⛔ The behaviour this whole module exists for. The preview stack had no
      # R2 secrets and stored reader photos on an ephemeral filesystem on a
      # machine that stops when idle, reporting nothing.
      assert {:error, message} = Selection.choose(%{}, true)

      assert message =~ "No object storage is configured"

      assert message =~ "lost on the next deploy",
             "the message must say what went wrong before, not just what to set"

      assert message =~ "STORAGE_BACKEND=local",
             "and must name the deliberate alternative, since local IS allowed"
    end

    test "allows local storage deliberately, because self-hosting is the point" do
      env = %{"STORAGE_BACKEND" => "local", "UPLOAD_DIR" => "/mnt/durable/uploads"}

      assert {:ok, {:local, opts}} = Selection.choose(env, true)
      assert opts[:upload_dir] == "/mnt/durable/uploads"
    end

    test "but refuses local storage that names no durable location" do
      assert {:error, message} = Selection.choose(%{"STORAGE_BACKEND" => "local"}, true)
      assert message =~ "requires UPLOAD_DIR"
    end
  end

  describe "what counts as 'set'" do
    test "a BLANK credential is absent, not present" do
      # ⛔ `System.get_env/1` answers `""` for a variable set to nothing, and
      # `""` is truthy in Elixir — so the original `if System.get_env(...)`
      # would have selected R2 on an empty secret and signed requests against
      # the host ".r2.cloudflarestorage.com". A secret store that can hold an
      # empty string makes this a real input.
      blanked = Map.put(@creds, "R2_ACCOUNT_ID", "")

      assert {:error, message} = Selection.choose(blanked, true)
      assert message =~ "No object storage is configured"
    end

    test "whitespace is blank too" do
      assert {:error, _} = Selection.choose(Map.put(@creds, "R2_ACCOUNT_ID", "   "), true)
    end

    test "a blank STORAGE_BACKEND is not an invalid value, it is no value" do
      assert {:ok, {:local, _}} = Selection.choose(%{"STORAGE_BACKEND" => ""}, false)
    end
  end

  describe "refusals name what is wrong" do
    test "an unknown backend is quoted back" do
      assert {:error, message} = Selection.choose(%{"STORAGE_BACKEND" => "s3"}, false)
      assert message =~ ~s(must be "r2" or "local")
      assert message =~ ~s("s3")
    end

    test "R2 selected with missing secrets names WHICH, so a deploy need not bisect" do
      env = %{"STORAGE_BACKEND" => "r2", "R2_ACCOUNT_ID" => "acct"}

      assert {:error, message} = Selection.choose(env, true)
      assert message =~ "R2_ACCESS_KEY_ID"
      assert message =~ "R2_SECRET_ACCESS_KEY"
      assert message =~ "R2_BUCKET_NAME"
      refute message =~ "R2_ACCOUNT_ID,", "the one that IS set must not be listed"
    end

    test "there is no default bucket to fall back to" do
      # The old code read `System.get_env("R2_BUCKET_NAME", "stacks-images")`,
      # so a stack that forgot the variable wrote into whichever bucket that
      # name resolved to — which is how one bucket came to hold objects from
      # more than one environment.
      env = Map.delete(@creds, "R2_BUCKET_NAME")

      assert {:error, message} = Selection.choose(Map.put(env, "STORAGE_BACKEND", "r2"), true)
      assert message =~ "R2_BUCKET_NAME"
    end
  end
end
