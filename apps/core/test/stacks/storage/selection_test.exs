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

  describe "the selector's decision reaches a released server" do
    # ⛔ THE FILE THIS READS IS THE POINT, AND I READ THE WRONG ONE FIRST.
    # This project is an umbrella (`apps_path: "apps"` in the root `mix.exs`), so
    # the runtime config a release evaluates is the ROOT `config/runtime.exs`.
    # `apps/core/config/runtime.exs` is not loaded in an umbrella build, which is
    # why it is a bare `import Config`.
    #
    # ⚠️ An earlier version of this test read `"config/runtime.exs"` relative to
    # the test's working directory — `apps/core` — and so asserted facts about a
    # file no deployed node ever evaluates. It passed. The path is resolved from
    # `__DIR__` now, and the existence assertion below fails loudly rather than
    # silently reading a decoy.
    @runtime_config Path.expand("../../../../../config/runtime.exs", __DIR__)

    setup do
      assert File.exists?(@runtime_config),
             "expected the umbrella's root runtime config at #{@runtime_config}; " <>
               "if it moved, update this path — these assertions are worthless " <>
               "against any other file"

      source = File.read!(@runtime_config)

      {:ok, runtime: source, code: strip_comments(source)}
    end

    # ⛔ AN ABSENCE ASSERTION MUST NOT READ THE PROSE THAT EXPLAINS THE ABSENCE.
    # The comment above this block quotes the banned line verbatim, so a scan of
    # the raw source matches its own documentation and fails forever — which is
    # exactly what happened on the first run of the test below. This is a
    # recurring shape in this repository, not a one-off slip.
    #
    # ⚠️ Full-line comments and whitespace-preceded trailing comments only, and
    # `\#{` is left alone so string interpolation is never mistaken for a comment.
    defp strip_comments(source) do
      source
      |> String.split("\n")
      |> Enum.map_join("\n", fn line ->
        if Regex.match?(~r/^\s*#/, line) do
          ""
        else
          Regex.replace(~r/\s#(?!\{).*$/, line, "")
        end
      end)
    end

    test "it is asked, rather than the backend being a compile-time default", %{runtime: runtime} do
      assert runtime =~ "Stacks.Storage.Selection.choose",
             "the release's runtime config must ask the selector; otherwise :storage keeps " <>
               "whatever was set at compile time and no deployed node ever chooses"

      assert runtime =~ "config_env() == :prod",
             "the selector must be told whether this is a deployed build — that argument is " <>
               "what decides whether a missing declaration is a default or a refusal"

      assert runtime =~ ~r/\{:error, [a-z_]+\} ->(.|\n)*raise/,
             "an unanswerable storage declaration must stop the boot, not fall back"
    end

    # ⛔ THE REGRESSION THIS CLOSES, MEASURED RATHER THAN IMAGINED. A line inside
    # the released-server branch read `config :core, upload_dir: "/tmp/uploads"`
    # and ran ~190 lines AFTER the selector, discarding the directory the selector
    # had derived from `UPLOAD_DIR`. On a preview the declaration was
    # `/app/uploads` and the booting node announced `/tmp/uploads`.
    #
    # ⚖️ Asserted as "nothing sets it to a literal", not "the file does not say
    # /tmp/uploads": the defect is a hardcoded destination overriding a declared
    # one, and it would be the same defect at any other path.
    test "nothing overrides the directory the selector derived", %{runtime: runtime, code: code} do
      # ⛔ ANTI-VACUITY FOR THE STRIPPER ITSELF, both directions. If it removed
      # nothing the scan reads prose again; if it removed everything the scan
      # passes against an empty string. Either way the assertion below would be
      # worthless, and worthless in a way that looks green.
      assert String.length(code) < String.length(runtime),
             "the comment stripper removed nothing — the scan below is reading prose"

      assert code =~ "Stacks.Storage.Selection.choose",
             "the comment stripper ate the code it was meant to preserve"

      literal_assignments =
        Regex.scan(~r/config\s+:core,\s*upload_dir:\s*"([^"]+)"/, code)

      assert literal_assignments == [],
             "the upload directory is being set to a hardcoded path " <>
               "(#{inspect(Enum.map(literal_assignments, &List.last/1))}), which overrides " <>
               "whatever UPLOAD_DIR declared. The selector refuses to boot a deployed build " <>
               "that names no durable location — a literal here throws that guarantee away " <>
               "and sends the bytes somewhere nobody promised to keep."
    end
  end
end
