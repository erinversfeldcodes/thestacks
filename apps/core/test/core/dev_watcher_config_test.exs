defmodule Core.DevWatcherConfigTest do
  @moduledoc """
  Drift guard for the dev asset watcher's working directory (Issue #278).

  `config/dev.exs` once computed the watcher `cd` as
  `Path.expand("../apps/core/assets", __DIR__)`, doubling the path to
  `<repo>/apps/core/apps/core/assets`. Phoenix then crash-looped the watcher
  (`:watcher_command_error`) and dev asset hot-rebuild was silently dead.

  Dev config never loads in the :test env, so this guard reads
  `config/dev.exs` directly via `Config.Reader.read!/1` — `__DIR__` inside the
  file still resolves to the real `config/` directory, exactly as it does when
  `mix phx.server` compiles it. The test fails if any configured watcher `cd`
  points at a directory that does not exist, or if the esbuild entrypoint
  (`build.js`) is missing from it.
  """

  use ExUnit.Case, async: true

  @dev_config_path Path.expand("../../config/dev.exs", __DIR__)

  test "every dev endpoint watcher cd is an existing directory containing build.js" do
    watchers =
      @dev_config_path
      |> Config.Reader.read!()
      |> get_in([:core, CoreWeb.Endpoint, :watchers])

    assert is_list(watchers) and watchers != [],
           "expected at least one watcher in #{@dev_config_path}"

    for {command, args} <- watchers do
      cd = args |> Enum.filter(&match?({:cd, _}, &1)) |> Keyword.get(:cd)

      assert is_binary(cd),
             "watcher #{inspect(command)} has no :cd option in #{@dev_config_path}"

      assert File.dir?(cd),
             "watcher #{inspect(command)} cd does not exist: #{cd} " <>
               "(regression of Issue #278 — doubled apps/core path?)"

      assert File.exists?(Path.join(cd, "build.js")),
             "watcher #{inspect(command)} cd exists but has no build.js: #{cd}"
    end
  end
end
